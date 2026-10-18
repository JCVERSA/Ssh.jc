# Ssh.jc — scripts d’administration VPS et Ollama

Ce dépôt contient deux outils indépendants pour les VPS et conteneurs Debian/Ubuntu :

1. **`Install.sh`** — installe et expose un accès SSH via Cloudflare Tunnel ou fxTunnel, avec un pack optionnel d’outils VPS essentiels.
2. **`ollama-cloudflare-setup.sh`** — installe Ollama et l’expose via Cloudflare Tunnel, puis fournit la commande courte **`ola`** pour gérer le service, les modèles, la fiabilité et les diagnostics.

> ⚠️ **Avertissement important pour la partie Ollama** : le tunnel créé par `ollama-cloudflare-setup.sh` est **public et sans authentification**. Le script ne configure volontairement pas Cloudflare Access. Toute personne qui connaît l’URL publique peut appeler l’API Ollama, générer des réponses et consommer les ressources du sandbox. Ne partage l’URL qu’en connaissance de cause.

## Sommaire

- [Partie 1 — `Install.sh` : SSH + tunnels](#partie-1--installsh--ssh--tunnels)
- [Partie 2 — Ollama + Cloudflare avec `ola`](#partie-2--ollama--cloudflare-avec-ola)
  - [Vue d’ensemble](#vue-densemble)
  - [Prérequis](#prérequis)
  - [Installation](#installation)
  - [Quick Tunnel ou Named Tunnel](#quick-tunnel-ou-named-tunnel)
  - [Configuration](#configuration)
  - [Guide d’utilisation `ola`](#guide-dutilisation-ola)
  - [Gestion interactive des modèles](#gestion-interactive-des-modèles)
  - [Utiliser l’API Ollama](#utiliser-lapi-ollama)
  - [Fonctionnement 24/7, watchdog et récupération](#fonctionnement-247-watchdog-et-récupération)
  - [Mettre à jour `ola`](#mettre-à-jour-ola)
  - [Dépannage](#dépannage)
  - [Sécurité](#sécurité)
  - [Désactivation](#désactivation)
  - [FAQ](#faq)
- [Fichiers du dépôt](#fichiers-du-dépôt)

---

# Partie 1 — `Install.sh` : SSH + tunnels

Script d’installation interactif pour exposer un accès SSH via **Cloudflare Tunnel** ou **fxTunnel**, principalement sur Ubuntu/Debian.

## Installation rapide sur un VPS

Exécute cette commande sur le VPS :

```bash
cd /tmp && curl -fsSL https://raw.githubusercontent.com/JCVERSA/Ssh.jc/arena/e89a71aa-ssh-jc/Install.sh -o Install.sh && chmod +x Install.sh && ./Install.sh
```

Le script affiche ensuite un menu interactif :

1. Installation complète SSH + tunnel
2. OpenSSH uniquement
3. Client tunnel uniquement
4. Créer/configurer un tunnel
5. Lancer un tunnel enregistré
6. Gérer les tunnels enregistrés
7. Installer les outils VPS essentiels
8. Quitter

## Outils VPS essentiels (menu 7)

Le choix **7** installe un pack d’administration VPS. Il est aussi proposé, de façon optionnelle, au début de l’installation complète (choix 1).

Le pack comprend :

- outils de base et de compilation : `build-essential`, `curl`, `wget`, `git`, `vim`, `nano`, `unzip`, `zip`, `ca-certificates`, `gnupg`, `apt-transport-https`, `sudo` ;
- confort d’administration : `tmux`, `screen`, `htop`, `net-tools`, `ufw`, `fail2ban`, `rsync`, `jq`, `dnsutils`, `lsof` ;
- Python : `python3`, `python3-venv`, `python3-pip` ;
- Node.js : le script demande la version majeure à installer (**20 LTS** ou **22**) via NodeSource, puis installe `nodejs` et `pm2` en global ;
- `cloudflared` : le script essaie d’abord le dépôt apt officiel Cloudflare ; en cas d’échec, il utilise en secours le paquet `.deb` GitHub vérifié par SHA-256.

Le pack est “best-effort” : si un composant échoue, les autres sont quand même tentés et les échecs sont résumés dans le log. Dans le menu dédié, le script termine avec une erreur si au moins un composant a échoué ; dans l’installation complète, il avertit et continue vers SSH + tunnel.

## Et si `sudo` est absent ?

Sur les images VPS minimales, `sudo` n’est pas toujours installé. `Install.sh` essaie maintenant de l’installer automatiquement, sans casser le script si une méthode échoue :

- en root : `apt-get`, `apt`, `dnf`, `microdnf`, `yum`, `apk`, `pacman`, `zypper`, `xbps-install` ;
- en utilisateur normal : une tentative via `su` (mot de passe root demandé), avec ajout de l’utilisateur au groupe `sudo` si possible.

Si toutes les tentatives échouent, le script s’arrête proprement avec les commandes manuelles à lancer. Exemple Debian/Ubuntu en root :

```bash
apt-get update && apt-get install -y sudo
```

Si ton compte vient juste d’être ajouté au groupe `sudo`, reconnecte ta session SSH puis relance le script.

## Notes de sécurité pour `Install.sh`

- Le script rend SSH joignable depuis Internet une fois le tunnel lancé : préfère un utilisateur admin dédié avec clé SSH, puis désactive l’authentification par mot de passe quand c’est proposé.
- Avant modification, `sshd_config` est sauvegardé et vérifié avec `sshd -t` / `sshd -T`.
- Les paquets/scripts distants sans checksum vérifiable ne sont pas installés automatiquement.

---

# Partie 2 — Ollama + Cloudflare avec `ola`

## Vue d’ensemble

`ollama-cloudflare-setup.sh` installe et supervise une instance Ollama accessible par un tunnel Cloudflare :

```text
Client / application
        │
        │ HTTPS
        ▼
Cloudflare
        │
        │ Cloudflare Tunnel sortant
        ▼
cloudflared dans le sandbox
        │
        │ http://127.0.0.1:11434
        ▼
Ollama (écoute locale uniquement)
        │
        ▼
Modèle chargé en RAM
```

Principes :

- **Ollama n’écoute pas directement sur Internet** : il est lié à `127.0.0.1:11434`.
- **cloudflared** crée une connexion sortante vers Cloudflare et relaie le trafic vers Ollama.
- **Supervisor** supervise trois programmes :
  - `ollama` ;
  - `cloudflared-ollama` ;
  - `ollama-watchdog`.
- La commande courte **`ola`** est installée dans `/usr/local/bin/ola`.
- Les téléchargements d’Ollama et de cloudflared sont vérifiés quand un checksum est disponible.
- Ollama est volontairement limité pour les petits sandboxes : un seul modèle chargé, une requête parallèle et un contexte de 1024 tokens par défaut.

## Prérequis

### Système

- Conteneur ou VPS Debian/Ubuntu, ou distribution compatible Debian.
- Accès **root** pour l’installation et les opérations qui modifient les services.
- Connexion Internet sortante vers :
  - GitHub et `raw.githubusercontent.com` pour récupérer le script et Ollama ;
  - Debian/Ubuntu pour les paquets `apt` ;
  - `pkg.cloudflare.com` et/ou GitHub pour cloudflared ;
  - Cloudflare pour établir le tunnel.
- `curl`, `jq`, `tar`, `sha256sum`, Supervisor et les outils de base sont installés automatiquement pendant le setup quand `apt` est disponible.

Aucun port entrant n’a besoin d’être ouvert ou redirigé pour le tunnel : cloudflared fonctionne en connexion sortante.

### Ressources recommandées

Configuration minimale conseillée pour les petits modèles utilisés par défaut :

- **RAM : 2 Go** pour `llama3.2:1b` et les modèles d’environ 1 à 1,5 Go ;
- **disque : au moins 5 Go libres** avant une installation complète ;
- un sandbox qui reste actif si l’objectif est une disponibilité 24/7.

À titre indicatif :

- l’archive Ollama fait environ **1,37 Go** ;
- le modèle `llama3.2:1b` occupe environ **1,3 Go** sur le disque ;
- le setup vérifie l’espace avant le téléchargement/extraction et choisit un dossier temporaire assez grand, ce qui évite le piège classique d’un `/tmp` limité à 1 Go.

Les modèles plus gros peuvent nécessiter beaucoup plus de RAM et de disque. En cas de doute, commence par un modèle 1B ou 1.5B et vérifie avec `ola doctor`.

### Pour le mode Named Tunnel

En plus des prérequis ci-dessus, il faut :

- un compte Cloudflare ;
- un domaine ou une zone DNS gérée par Cloudflare ;
- un hostname libre, par exemple `ollama.example.com` ;
- pouvoir ouvrir l’URL de connexion Cloudflare dans un navigateur pendant le setup.

## Installation

### 1. Télécharger le script

Sur le sandbox ou le VPS, en root :

```bash
cd /tmp
curl -fsSLO https://raw.githubusercontent.com/JCVERSA/Ssh.jc/arena/e89a71aa-ssh-jc/ollama-cloudflare-setup.sh
chmod +x ollama-cloudflare-setup.sh
```

Le script peut aussi être lancé avec `sudo` depuis un compte administrateur :

```bash
sudo ./ollama-cloudflare-setup.sh
```

### 2. Lancer l’installation

Sans argument, le script ouvre le menu interactif :

```bash
./ollama-cloudflare-setup.sh
```

Choisis :

```text
1) Full setup (Ollama + model + tunnel)
```

Le setup effectue notamment les étapes suivantes :

1. vérifie le système et les commandes requises ;
2. installe ou met à jour la commande courte `ola` ;
3. installe Supervisor si nécessaire et le démarre ;
4. active le watchdog de santé ;
5. installe Ollama depuis l’archive officielle GitHub vérifiée par SHA-256 ;
6. démarre Ollama sous Supervisor, lié uniquement à `127.0.0.1:11434` ;
7. demande le modèle à télécharger ;
8. décharge d’abord, si besoin, un autre modèle déjà présent en RAM ;
9. télécharge le modèle choisi ;
10. installe cloudflared, d’abord via le dépôt apt officiel Cloudflare, puis en secours via le paquet GitHub vérifié ;
11. demande le mode de tunnel : Quick Tunnel ou Named Tunnel ;
12. démarre et vérifie le tunnel ;
13. affiche le statut final et l’URL publique.

Forme non interactive équivalente pour démarrer le setup :

```bash
./ollama-cloudflare-setup.sh setup
```

Le setup reste interactif pour le choix du modèle et du tunnel.

### 3. Première vérification

À la fin de l’installation, la commande courte est disponible. Les trois commandes de contrôle essentielles sont :

```bash
ola status
ola doctor
ola test
```

- `ola status` : état rapide des services, de l’API, du modèle et de l’URL publique ;
- `ola doctor` : diagnostic complet avec résumé des échecs et avertissements ;
- `ola test` : teste l’API locale, le modèle, une mini-conversation et l’API publique.

`ola doctor` doit idéalement se terminer par :

```text
--- Doctor summary: 0 failure(s), 0 warning(s) ---
```

## Quick Tunnel ou Named Tunnel

Pendant le setup, le script propose deux modes.

| Critère | Quick Tunnel | Named Tunnel |
|---|---|---|
| Choix dans le setup | `1` | `2` |
| Compte Cloudflare requis | Non | Oui |
| Domaine requis | Non | Oui |
| URL | Aléatoire en `*.trycloudflare.com` | Hostname choisi, par exemple `ollama.example.com` |
| Stabilité de l’URL | Temporaire, peut changer | Persistante tant que le tunnel et le DNS existent |
| Usage conseillé | Test rapide | Usage durable / 24/7 |

### Quick Tunnel

Le Quick Tunnel est le plus simple : Cloudflare attribue une URL temporaire du type :

```text
https://quelque-chose.trycloudflare.com
```

L’URL est enregistrée dans `/etc/ollama-cloudflare-url` et affichée par `ola status`.

Limites :

- l’URL peut changer si le tunnel est recréé ;
- ce mode est plutôt adapté aux essais ;
- l’API reste publique sans authentification.

### Named Tunnel

Le Named Tunnel est recommandé pour un usage durable. Le setup demande :

```text
Tunnel name [ollama-vps]:
Public hostname (e.g. ollama.example.com):
```

Exemple :

```text
Tunnel name: ollama-vps
Public hostname: ollama.example.com
```

Le script :

1. ouvre la page de connexion Cloudflare si aucun certificat local n’est présent ;
2. attend que tu te connectes et que tu autorises le domaine dans le navigateur ;
3. réutilise le certificat existant s’il le trouve déjà dans `/root/.cloudflared`, dans `$HOME/.cloudflared` ou dans le home de l’utilisateur `sudo` ;
4. crée ou réutilise le tunnel nommé ;
5. copie les credentials du tunnel dans `/etc/cloudflared/` avec des permissions strictes ;
6. génère `/etc/cloudflared/config.yml` ;
7. valide la configuration avec `cloudflared tunnel ingress validate` ;
8. démarre cloudflared sous Supervisor ;
9. crée ou met à jour l’enregistrement DNS Cloudflare ;
10. vérifie que `https://<hostname>/api/version` répond ;
11. enregistre l’URL publique.

Si le serveur lui-même ne sait pas encore résoudre le hostname public, la vérification publique peut passer par Cloudflare DNS-over-HTTPS et un test équivalent à `curl --resolve`. Un échec de résolution DNS local dans le sandbox ne signifie donc pas forcément que le tunnel est hors ligne depuis Internet.

## Configuration

### La commande `ola`

Le setup installe une copie stable du script ici :

```text
/usr/local/lib/ollama-cloudflare/ollama-cloudflare-setup.sh
```

et crée le lien de commande :

```text
/usr/local/bin/ola
  -> /usr/local/lib/ollama-cloudflare/ollama-cloudflare-setup.sh
```

Conséquences :

- tu peux taper `ola` depuis n’importe quel dossier ;
- `ola` continue de fonctionner même si le fichier téléchargé dans `/tmp` est supprimé ;
- lancer une nouvelle version du script avec `setup`, `start`, `recover`, `use`, `unload` ou `delete` met aussi à jour la copie stable ;
- si `/usr/local/bin/ola` appartient déjà à un autre outil, le script refuse de l’écraser.

### Programmes supervisés

Supervisor gère les programmes suivants :

| Programme | Rôle | Redémarrage automatique |
|---|---|---|
| `ollama` | Serveur Ollama local | Oui |
| `cloudflared-ollama` | Tunnel Cloudflare vers Ollama | Oui |
| `ollama-watchdog` | Contrôle de santé et redémarrage ciblé | Oui |

Les configurations générées se trouvent dans :

```text
/etc/supervisor/conf.d/ollama.conf
/etc/supervisor/conf.d/cloudflared-ollama.conf
/etc/supervisor/conf.d/ollama-watchdog.conf
```

Le fichier principal Supervisor détecté peut être :

```text
/etc/supervisor/supervisord.conf
```

ou, sur certaines distributions :

```text
/etc/supervisord.conf
```

### Paramètres Ollama générés

Le programme Supervisor `ollama` utilise notamment :

```ini
OLLAMA_HOST="127.0.0.1:11434"
OLLAMA_ORIGINS="*"
OLLAMA_CONTEXT_LENGTH="1024"
OLLAMA_KEEP_ALIVE="5m"
OLLAMA_MAX_LOADED_MODELS="1"
OLLAMA_NUM_PARALLEL="1"
HOME="/var/lib/ollama"
```

Explications :

- `OLLAMA_HOST="127.0.0.1:11434"` : Ollama reste local, il n’écoute pas directement sur toutes les interfaces ;
- `OLLAMA_ORIGINS="*"` : autorise les requêtes venant du tunnel malgré le contrôle d’origine d’Ollama ;
- le Host public est réécrit par cloudflared en `localhost:11434`, ce qui évite le second contrôle Ollama qui rejette les hostnames publics ;
- `OLLAMA_CONTEXT_LENGTH` : taille de contexte par défaut, volontairement basse pour les petits sandboxes ;
- `OLLAMA_KEEP_ALIVE="5m"` : un modèle inactif peut être déchargé après 5 minutes ;
- `OLLAMA_MAX_LOADED_MODELS="1"` : objectif d’un seul modèle chargé en RAM sur une nouvelle installation ;
- `OLLAMA_NUM_PARALLEL="1"` : une seule requête à la fois, plus sûr en RAM.

Ces paramètres sont écrits dans la configuration Supervisor au moment du setup. Pour les modifier proprement, ajuste les variables ci-dessous puis relance un setup, ou modifie la configuration Supervisor puis recharge-la avec `ola start`.

### Variables d’environnement utiles

Ces variables se placent **avant** la commande de setup ou la commande concernée.

| Variable | Défaut | Effet |
|---|---:|---|
| `OLLAMA_TMPDIR` | Choix automatique | Force le dossier temporaire volumineux utilisé pour l’archive Ollama et les téléchargements cloudflared de secours. Utile si `/tmp` est petit. |
| `OLLAMA_CONTEXT_LENGTH` | `1024` | Contexte Ollama écrit dans la configuration Supervisor pendant le setup. Augmenter le contexte augmente la RAM utilisée. |
| `CF_TUNNEL_PROTOCOL` | `auto` | Protocole cloudflared : `auto`, `http2` ou `quic`. Écrit dans la configuration du tunnel pendant le setup. |

Exemples :

Forcer un dossier temporaire sur un disque plus grand :

```bash
OLLAMA_TMPDIR=/var/tmp ./ollama-cloudflare-setup.sh setup
```

Forcer HTTP/2 si le réseau bloque UDP/QUIC :

```bash
CF_TUNNEL_PROTOCOL=http2 ./ollama-cloudflare-setup.sh setup
```

Augmenter prudemment le contexte :

```bash
OLLAMA_CONTEXT_LENGTH=2048 ./ollama-cloudflare-setup.sh setup
```

Attention : après avoir changé `OLLAMA_CONTEXT_LENGTH` ou `CF_TUNNEL_PROTOCOL`, il faut régénérer la configuration concernée avec un nouveau setup. `ola start` redémarre les services mais ne réécrit pas toutes les configurations.

### Fichiers importants

| Chemin | Contenu |
|---|---|
| `/usr/local/bin/ola` | Commande courte, lien vers le script installé |
| `/usr/local/lib/ollama-cloudflare/ollama-cloudflare-setup.sh` | Copie stable du gestionnaire |
| `/etc/supervisor/supervisord.conf` | Configuration principale Supervisor, selon la distribution |
| `/etc/supervisor/conf.d/ollama.conf` | Programme Supervisor Ollama |
| `/etc/supervisor/conf.d/cloudflared-ollama.conf` | Programme Supervisor du tunnel |
| `/etc/supervisor/conf.d/ollama-watchdog.conf` | Programme Supervisor du watchdog |
| `/var/log/supervisor/ollama.log` | Logs standard Ollama |
| `/var/log/supervisor/ollama-error.log` | Logs d’erreur et détails d’inférence Ollama |
| `/var/log/supervisor/cloudflared-ollama.log` | Logs standard cloudflared |
| `/var/log/supervisor/cloudflared-ollama-error.log` | Logs détaillés cloudflared |
| `/var/log/supervisor/ollama-watchdog.log` | Événements du watchdog |
| `/var/log/supervisor/ollama-watchdog-error.log` | Erreurs du watchdog |
| `/etc/cloudflared/config.yml` | Configuration du Named Tunnel |
| `/etc/cloudflared/<UUID>.json` | Credentials du Named Tunnel, fichier sensible |
| `$HOME/.cloudflared/cert.pem` | Certificat de connexion Cloudflare du CLI, fichier sensible |
| `/etc/ollama-cloudflare-url` | URL publique enregistrée |
| `/etc/ollama-cloudflare-model` | Modèle par défaut utilisé par `ola test` et le gestionnaire |
| `/var/lib/ollama/` | Home du service Ollama |
| `/var/lib/ollama/.ollama/models/` | Modèles téléchargés sur le disque |

Les logs Supervisor sont limités par rotation : 10 Mo par fichier avec 3 fichiers conservés, afin d’éviter de remplir un petit disque.

### Configuration Named Tunnel générée

Exemple simplifié de `/etc/cloudflared/config.yml` :

```yaml
tunnel: <UUID>
credentials-file: /etc/cloudflared/<UUID>.json
no-autoupdate: true
ingress:
  - hostname: ollama.example.com
    service: http://127.0.0.1:11434
    originRequest:
      httpHostHeader: "localhost:11434"
  - service: http_status:404
```

Si `CF_TUNNEL_PROTOCOL=http2` ou `quic` est choisi au setup, une ligne `protocol: ...` est ajoutée. En mode `auto`, cloudflared choisit et peut basculer vers HTTP/2 si QUIC échoue.

Ne publie jamais le contenu de `/etc/cloudflared/<UUID>.json` ni de `cert.pem`.

## Guide d’utilisation `ola`

### Syntaxe générale

```bash
ola
ola help
ola status
ola doctor
ola test
ola models
ola use <modèle>
ola ps
ola unload
ola delete <modèle>
ola recover
ola start
ola logs
ola watchdog
ola stop
ola setup
```

`ola` sans argument ouvre le menu interactif complet.

Les commandes qui modifient les services ou les modèles demandent root :

- `setup`, `start`, `restart`, `recover`, `stop` ;
- `use`, `unload`, `delete`/`rm` ;
- dans le gestionnaire `ola models`, les actions `u`, `d`, `l` et `a`.

Les commandes suivantes sont en lecture seule :

- `status`, `doctor`, `test`, `ps`, `logs`, `watchdog` ;
- `ola models` en affichage simple, ou en mode lecture seule si tu n’es pas root.

En root, lance-les simplement. Depuis un utilisateur administrateur, utilise `sudo ola ...` pour les commandes d’écriture.

### Référence des commandes

| Commande | Description |
|---|---|
| `ola` | Ouvre le menu interactif. |
| `ola help` ou `ola --help` | Affiche l’aide courte. |
| `ola setup` | Lance ou relance l’installation complète et régénère les configurations. |
| `ola status` | Affiche Supervisor, l’API locale, les modèles connus et l’URL publique enregistrée. |
| `ola doctor` | Diagnostic complet : binaires, Supervisor, services, API, modèles, tunnel, RAM, disque, logs et URL publique. |
| `ola test` | Teste l’API locale, vérifie le modèle par défaut, fait une mini-conversation et teste l’URL publique. |
| `ola models` | En terminal interactif, ouvre le gestionnaire de modèles. Sinon, affiche simplement la liste des modèles téléchargés. |
| `ola use <modèle>` | Change de modèle : décharge d’abord les autres modèles en RAM, télécharge si besoin, charge le modèle demandé et le définit comme défaut pour `ola`. |
| `ola ps` | Liste les modèles actuellement chargés en RAM. |
| `ola unload` | Décharge tous les modèles de la RAM, sans arrêter Ollama. |
| `ola unload <modèle>` | Décharge un modèle précis de la RAM. |
| `ola delete <modèle>` | Décharge le modèle de la RAM si besoin, puis le supprime définitivement du disque. Alias : `ola rm <modèle>`. |
| `ola delete <modèle> --force` | Force la suppression même si c’est le modèle par défaut. |
| `ola recover` | Répare les services arrêtés ou non sains sans redémarrer inutilement ce qui fonctionne. |
| `ola start` | Redémarre Ollama et cloudflared. Alias : `ola restart`. Interruption brève. |
| `ola logs` | Affiche les dernières lignes des logs Ollama et cloudflared. |
| `ola watchdog` | Affiche l’état du watchdog et ses derniers événements. |
| `ola stop` | Arrête le tunnel cloudflared et supprime l’URL publique enregistrée. Ollama continue de tourner localement. |

### Workflow quotidien recommandé

Vérification rapide :

```bash
ola status
```

Diagnostic complet en cas de doute :

```bash
ola doctor
```

Test fonctionnel de bout en bout :

```bash
ola test
```

Après un redémarrage du sandbox, si les fichiers sont conservés :

```bash
ola recover
```

Redémarrage volontaire complet :

```bash
ola start
```

Arrêt du tunnel public uniquement :

```bash
ola stop
```

## Gestion interactive des modèles

### Ouvrir le gestionnaire

Dans un vrai terminal :

```bash
ola models
```

Exemple d’écran :

```text
================ Modèles Ollama ================
 1) llama3.2:1b                      1.3 GB [défaut] [RAM]
 2) qwen2.5:1.5b                     986 MB
--------------------------------------------------
u = utiliser    d = supprimer    l = libérer la RAM
a = ajouter + utiliser un autre modèle
r = rafraîchir  q = quitter
```

Marqueurs :

- **[défaut]** : modèle enregistré comme modèle par défaut pour `ola test` et le gestionnaire ;
- **[RAM]** : modèle actuellement chargé en mémoire.

### Touches du gestionnaire

Tu tapes la lettre puis **Entrée** :

| Touche | Action |
|---|---|
| `u` | Utiliser le modèle sélectionné |
| `d` | Supprimer définitivement le modèle sélectionné du disque |
| `l` | Libérer le modèle sélectionné de la RAM |
| `a` | Ajouter puis utiliser un nouveau modèle |
| `r` | Rafraîchir la liste |
| `q` | Quitter |

Pour `u`, `d` et `l`, le gestionnaire demande ensuite le **numéro** du modèle dans la liste.

Exemple pour utiliser le modèle n° 2 :

```text
Action : u
Numéro du modèle : 2
```

Exemple pour supprimer le modèle n° 2 :

```text
Action : d
Numéro du modèle : 2
```

Aucune confirmation `DELETE` n’est demandée dans le gestionnaire interactif : le choix de l’action `d` et du numéro du modèle déclenche immédiatement la suppression.

Après chaque action, la liste est réaffichée avec les nouveaux marqueurs.

En mode non interactif, par exemple dans un pipe ou un script, `ola models` garde un comportement simple et affiche seulement la liste, sans ouvrir le gestionnaire.

### `ola use` : changer de modèle en économisant la RAM

Commande :

```bash
ola use qwen2.5:1.5b
```

Ordre exact des opérations :

1. lecture des modèles actuellement chargés en RAM via `/api/ps` ;
2. déchargement immédiat de tout modèle chargé différent de la cible, avec `keep_alive: 0` ;
3. vérification que l’ancien modèle a bien disparu de la RAM ;
4. téléchargement de la cible seulement si elle n’est pas déjà sur le disque ;
5. second nettoyage si un autre modèle s’est chargé pendant le téléchargement ;
6. chargement de la cible avec une mini-requête de test ;
7. enregistrement de la cible comme modèle par défaut pour `ola`.

Exemple :

```bash
ola use llama3.2:1b
ola use qwen2.5:1.5b
ola ps
```

Important :

- l’ancien modèle est **déchargé de la RAM**, mais **pas supprimé du disque** ;
- revenir à l’ancien modèle ne nécessite donc pas de le retélécharger ;
- si un modèle est en pleine génération et refuse de se décharger, le changement est interrompu plutôt que de risquer deux modèles lourds en RAM ;
- les applications qui appellent directement l’API Ollama doivent toujours indiquer le nom du modèle dans chaque requête : Ollama n’a pas de modèle par défaut global côté API. `ola use` définit le défaut pour les outils `ola` et charge immédiatement le modèle choisi.

### `ola ps` : voir ce qui occupe la RAM

```bash
ola ps
```

Exemple :

```text
Models currently loaded in RAM:
qwen2.5:1.5b
```

Si aucun modèle n’est chargé :

```text
No model is currently loaded in RAM.
```

### `ola unload` : libérer la RAM sans supprimer

Décharger tous les modèles :

```bash
ola unload
```

Décharger un seul modèle :

```bash
ola unload qwen2.5:1.5b
```

Le service Ollama continue de fonctionner. Le prochain appel rechargera le modèle demandé, avec un premier temps de réponse plus long.

### `ola models` : voir les modèles sur le disque

En terminal interactif, cette commande ouvre le gestionnaire décrit ci-dessus. En sortie simple, elle affiche les modèles téléchargés :

```bash
ola models
```

Exemple :

```text
Models currently downloaded on disk:
llama3.2:1b
qwen2.5:1.5b
```

### `ola delete` : supprimer définitivement un modèle du disque

Supprimer un modèle :

```bash
ola delete qwen2.5:1.5b
```

Alias :

```bash
ola rm qwen2.5:1.5b
```

Comportement :

1. vérifie que le modèle existe sur le disque ;
2. le décharge d’abord de la RAM s’il y est ;
3. envoie la suppression à l’API Ollama ;
4. vérifie qu’il a disparu de la liste des modèles téléchargés.

#### Protection du modèle par défaut

La suppression du modèle par défaut est refusée sans `--force`, pour éviter de laisser `ola test` sans modèle valide :

```bash
ola delete llama3.2:1b
```

Message attendu : il faut d’abord changer de modèle ou forcer.

Changement propre recommandé :

```bash
ola use qwen2.5:1.5b
ola delete llama3.2:1b
```

Suppression forcée :

```bash
ola delete llama3.2:1b --force
```

Si d’autres modèles restent, le premier modèle restant devient le nouveau défaut. Si aucun modèle ne reste, le fichier de défaut est retiré et il faudra installer un modèle avec `ola use <modèle>`.

Différence essentielle :

- `ola unload` = libère la RAM, conserve le modèle sur le disque ;
- `ola delete` = libère la RAM si besoin **et supprime définitivement les fichiers du modèle**.

## Utiliser l’API Ollama

L’URL publique enregistrée est affichée par :

```bash
ola status
```

Dans les exemples ci-dessous, remplace `https://ton-hostname.example` par ton URL publique réelle et `llama3.2:1b` par ton modèle.

### Tester la version

Depuis le sandbox :

```bash
curl -fsS http://127.0.0.1:11434/api/version
```

Depuis ton ordinateur ou un autre appareil :

```bash
curl -fsS https://ton-hostname.example/api/version
```

Réponse attendue :

```json
{"version":"0.40.6"}
```

### Lister les modèles téléchargés

```bash
curl -fsS https://ton-hostname.example/api/tags
```

### Voir les modèles chargés en RAM

```bash
curl -fsS https://ton-hostname.example/api/ps
```

ou, dans le sandbox :

```bash
ola ps
```

### Conversation avec `/api/chat`

```bash
curl -fsS https://ton-hostname.example/api/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "llama3.2:1b",
    "messages": [
      {"role": "user", "content": "Explique-moi simplement ce qu'est un tunnel Cloudflare."}
    ],
    "stream": false
  }'
```

En cas d’erreur de frappe dans l’URL copiée depuis un chat, préfère construire l’URL à partir de `ola status` plutôt que de recopier un lien formaté.

### Compatibilité OpenAI : `/v1`

Ollama expose aussi des endpoints compatibles OpenAI. Les tests effectués sur ce projet incluent `/v1/models` et `/v1/chat/completions`.

Base URL à configurer dans un client compatible :

```text
https://ton-hostname.example/v1
```

Paramètres usuels :

```text
API key : ollama
Model   : llama3.2:1b
```

La clé `ollama` est une valeur de remplissage pour les clients qui exigent une clé ; elle n’ajoute pas d’authentification réelle, puisque le tunnel reste public.

Exemple :

```bash
curl -fsS https://ton-hostname.example/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ollama' \
  -d '{
    "model": "llama3.2:1b",
    "messages": [
      {"role": "user", "content": "Dis bonjour en une phrase."}
    ]
  }'
```

## Fonctionnement 24/7, watchdog et récupération

### Ce qui redémarre automatiquement

Si le sandbox reste actif et que Supervisor reste en vie :

- si **Ollama** crash, Supervisor le redémarre ;
- si **cloudflared** crash, Supervisor le redémarre ;
- si la connexion Cloudflare tombe temporairement, cloudflared tente de se reconnecter et le watchdog surveille son état de readiness ;
- les logs ne remplissent pas indéfiniment le disque grâce à la rotation.

Le watchdog `ollama-watchdog` ajoute un contrôle de santé que Supervisor seul ne fait pas :

- vérification toutes les **60 secondes** ;
- Ollama : test de `http://127.0.0.1:11434/api/version` ;
- cloudflared : test de son endpoint local de readiness sur `127.0.0.1:20241/ready` ;
- redémarrage seulement après **3 échecs consécutifs** ;
- pause de **180 secondes** après un redémarrage pour éviter les boucles ;
- aucun redémarrage forcé si l’état cloudflared est seulement inconnu.

Voir le watchdog :

```bash
ola watchdog
```

### Ce qui n’est pas garanti

Aucun script interne ne peut garantir un 24/7 absolu si :

- la plateforme arrête, met en pause ou supprime le sandbox ;
- le sandbox est recréé depuis une image vierge ;
- la plateforme tue tout l’arbre de processus, y compris Supervisor ;
- la RAM ou le disque sont totalement saturés ;
- le tunnel ou les credentials sont supprimés côté Cloudflare ;
- le réseau de la plateforme est coupé durablement.

### Après un redémarrage du sandbox

Si le sandbox redémarre **en conservant son système de fichiers**, lance :

```bash
ola recover
```

`ola recover` :

- relance Supervisor si nécessaire ;
- démarre seulement les programmes arrêtés ;
- redémarre Ollama une fois si le processus tourne mais que l’API ne répond pas ;
- redémarre cloudflared seulement s’il se déclare explicitement non prêt ;
- ne redémarre pas inutilement les services sains ;
- affiche le statut final.

Si la plateforme propose un champ **Startup command**, **Start command** ou **Run on boot**, tu peux y mettre :

```bash
/usr/local/bin/ola start
```

ou :

```bash
ola start
```

Cela ne suffit que si le système de fichiers est conservé. Si le sandbox est recréé à neuf, relance un setup complet.

### Surveillance externe recommandée

Un watchdog interne ne peut pas signaler que tout le sandbox est éteint. Pour être alerté dans ce cas, surveille depuis un service externe cette URL :

```text
https://ton-hostname.example/api/version
```

Elle doit répondre HTTP 200 avec un JSON de version.

## Mettre à jour `ola`

Pour installer une nouvelle version du gestionnaire sur un sandbox déjà configuré :

```bash
cd /tmp
curl -fsSLO https://raw.githubusercontent.com/JCVERSA/Ssh.jc/arena/e89a71aa-ssh-jc/ollama-cloudflare-setup.sh
chmod +x ollama-cloudflare-setup.sh
./ollama-cloudflare-setup.sh start
```

Puis vérifie :

```bash
ola doctor
ola test
ola watchdog
```

`start` redémarre brièvement Ollama et cloudflared. La copie stable de `ola` est remplacée par la nouvelle version.

Si une mise à jour modifie les paramètres de génération des configurations — par exemple `OLLAMA_CONTEXT_LENGTH`, `CF_TUNNEL_PROTOCOL`, les paramètres Supervisor d’Ollama ou la configuration du tunnel — relance plutôt un setup pour régénérer proprement les fichiers concernés :

```bash
ola setup
```

ou, sans la commande courte à jour :

```bash
./ollama-cloudflare-setup.sh setup
```

## Dépannage

Commence toujours par :

```bash
ola doctor
ola status
ola logs
```

### Le tunnel public répond `403`

Causes déjà rencontrées :

1. `OLLAMA_ORIGINS` absent ou incorrect ;
2. le Host public transmis à Ollama n’est pas réécrit en `localhost:11434`.

La configuration actuelle corrige les deux points :

- `OLLAMA_ORIGINS="*"` dans le programme Supervisor Ollama ;
- Quick Tunnel : `--http-host-header=localhost:11434` ;
- Named Tunnel : `originRequest.httpHostHeader: "localhost:11434"`.

Si tu as configuré le sandbox avec une très ancienne version, relance un setup avec la version actuelle pour régénérer les configurations, puis teste :

```bash
ola doctor
ola test
```

### Le sandbox ne résout pas son propre hostname public

Symptôme :

```text
curl: (6) Could not resolve host
```

Cela peut être un problème du résolveur local du conteneur alors que le tunnel fonctionne depuis l’extérieur. `ola doctor` et les vérifications du setup utilisent un repli par Cloudflare DNS-over-HTTPS et `curl --resolve`.

Teste aussi l’URL depuis ton téléphone, ton navigateur ou un autre réseau.

### Erreur de téléchargement Ollama ou `curl: (23)`

Cause fréquente : `/tmp` trop petit pour l’archive Ollama.

Vérifie :

```bash
df -h
ola doctor
```

Puis relance avec un dossier temporaire plus grand :

```bash
OLLAMA_TMPDIR=/var/tmp ./ollama-cloudflare-setup.sh setup
```

Le script choisit déjà automatiquement un grand dossier temporaire, mais `OLLAMA_TMPDIR` permet de forcer le chemin.

### Supervisor ou les services ne répondent plus

Essaie d’abord la récupération douce :

```bash
ola recover
```

Si nécessaire, redémarrage complet :

```bash
ola start
```

Puis :

```bash
ola status
ola doctor
ola logs
```

### Ollama est `RUNNING` mais l’API ne répond pas

Le watchdog devrait redémarrer Ollama après plusieurs échecs. Pour intervenir immédiatement :

```bash
ola recover
```

ou :

```bash
ola start
```

Vérifie aussi la RAM et les modèles chargés :

```bash
ola doctor
ola ps
```

### RAM saturée ou réponses très lentes

Vérifie le modèle chargé :

```bash
ola ps
```

Libère la RAM :

```bash
ola unload
```

Change pour un modèle plus petit :

```bash
ola use llama3.2:1b
```

Évite d’augmenter `OLLAMA_CONTEXT_LENGTH` sur un sandbox de 2 Go sans tester progressivement.

### cloudflared n’est pas prêt ou QUIC échoue

Consulte :

```bash
ola watchdog
ola logs
```

Si le réseau bloque UDP/QUIC, force HTTP/2 au prochain setup :

```bash
CF_TUNNEL_PROTOCOL=http2 ./ollama-cloudflare-setup.sh setup
```

En mode `auto`, cloudflared peut déjà retomber sur HTTP/2, mais le forcer aide sur certains réseaux restrictifs.

Les avertissements suivants sont généralement non bloquants si les connexions sont enregistrées :

- proxy ICMP / `ping_group_range` ;
- taille du buffer UDP insuffisante.

### Conflit d’enregistrement DNS pour un Named Tunnel

Si Cloudflare refuse de créer la route DNS parce qu’un enregistrement existe déjà pour le hostname :

1. ouvre le tableau de bord Cloudflare ;
2. vérifie l’enregistrement DNS du hostname ;
3. supprime-le ou repoints-le vers le bon tunnel ;
4. relance le setup.

### Certificat Cloudflare introuvable ou mauvais dossier

Le certificat de login du CLI se trouve normalement dans :

```text
$HOME/.cloudflared/cert.pem
```

Dans certains shells root de sandbox, `$HOME` peut valoir `/home/user` au lieu de `/root`. Le script cherche et adopte automatiquement un certificat existant dans plusieurs emplacements probables, y compris le home de l’utilisateur `sudo`.

En cas d’échec, relance le setup et termine la connexion dans le navigateur jusqu’au message de succès de cloudflared.

### Suppression du modèle par défaut refusée

Message normal de protection. Solutions :

```bash
ola use <autre-modèle>
ola delete <ancien-modèle>
```

ou, en connaissance de cause :

```bash
ola delete <modèle> --force
```

### Disque plein

Vérifie les modèles téléchargés :

```bash
ola models
```

Supprime ceux qui ne servent plus :

```bash
ola delete <modèle>
```

Vérifie aussi l’espace global :

```bash
df -h
```

Les logs Supervisor sont déjà limités par rotation.

## Sécurité

### Tunnel public sans authentification

Point le plus important : **il n’y a pas de Cloudflare Access et pas de mot de passe sur l’API Ollama exposée**.

Toute personne qui obtient l’URL peut notamment :

- appeler `/api/chat` et consommer CPU/RAM ;
- lister les modèles ;
- tenter de charger d’autres modèles déjà présents ;
- selon les endpoints utilisés et la version d’Ollama, tenter des opérations coûteuses comme un pull de modèle.

Bonnes pratiques compatibles avec ce choix :

- ne publie pas l’URL dans un dépôt, une capture d’écran ou un message public ;
- utilise plutôt un **Named Tunnel** avec un hostname que tu contrôles ;
- arrête le tunnel quand il ne sert pas :

  ```bash
  ola stop
  ```

- surveille l’usage et les logs :

  ```bash
  ola status
  ola logs
  ```

- dans Cloudflare, si ton usage le permet, ajoute des règles de limitation de débit ou des restrictions adaptées à tes adresses et pays d’accès. Cela ne remplace pas une authentification, mais réduit l’abus ;
- si l’URL ou les credentials fuient, supprime/recrée le tunnel ou change de hostname, puis relance le setup ;
- mets régulièrement à jour le sandbox, Ollama et cloudflared via un nouveau setup de la version actuelle du script.

### Credentials et permissions

- `/etc/cloudflared/<UUID>.json` et `cert.pem` sont des secrets : ne les affiche pas, ne les commite pas et ne les envoie pas dans un chat.
- La configuration du tunnel et les journaux sont protégés par des permissions restrictives.
- Plusieurs commandes d’administration demandent root. Évite de lancer le script téléchargé sans vérifier son origine.

### Origine des binaires

Pendant le setup :

- Ollama est installé depuis l’archive officielle GitHub après vérification SHA-256 ;
- le script essaie plusieurs formats d’archive publiés (`tar.zst`, puis formats compressés publiés) et refuse une archive sans checksum correspondant ;
- cloudflared est installé d’abord via le dépôt apt officiel Cloudflare ;
- si ce dépôt échoue, le script retombe sur le paquet GitHub dont le digest SHA-256 est vérifié dans les métadonnées de release.

## Désactivation

### Arrêter seulement le tunnel public

```bash
ola stop
```

Effet :

- cloudflared est arrêté ;
- l’URL publique enregistrée est supprimée ;
- Ollama continue de tourner en local ;
- le watchdog continue de tourner mais ignore le tunnel volontairement arrêté.

### Arrêter aussi Ollama et le watchdog

Commande Supervisor directe, en root :

```bash
supervisorctl -c /etc/supervisor/supervisord.conf stop ollama cloudflared-ollama ollama-watchdog
```

Les programmes restent configurés en démarrage automatique : ils peuvent revenir au prochain démarrage de Supervisor ou après un `ola start`.

### Désactivation persistante manuelle

Opération avancée, à faire seulement si tu veux retirer complètement cette installation :

1. arrête les programmes Supervisor ;
2. retire ou renomme les fichiers de programmes Supervisor générés — par défaut dans `/etc/supervisor/conf.d/`, ou dans le dossier équivalent détecté par `ola doctor` sur ta distribution :
   - `ollama.conf` ;
   - `cloudflared-ollama.conf` ;
   - `ollama-watchdog.conf` ;
3. recharge Supervisor ;
4. supprime éventuellement la route DNS et le tunnel dans Cloudflare ;
5. supprime les credentials et la configuration dans `/etc/cloudflared/` seulement si tu es certain de ne plus en avoir besoin.

Ces étapes ne sont pas automatisées par une commande `ola uninstall`. Fais une sauvegarde avant de supprimer les credentials : sans eux, un Named Tunnel existant ne pourra pas être redémarré tel quel.

## FAQ

### Quelle est la différence entre `ola stop`, `ola unload` et `ola delete` ?

- `ola stop` : arrête le **tunnel public** ;
- `ola unload` : décharge les modèles de la **RAM** ;
- `ola delete` : supprime un modèle du **disque**, définitivement.

### `ola use` supprime-t-il l’ancien modèle ?

Non. Il le **décharge de la RAM** pour économiser la mémoire, mais les fichiers restent sur le disque. Utilise `ola delete` pour les supprimer.

### Pourquoi le premier message est-il lent après `ola unload` ?

Parce que le modèle doit être rechargé depuis le disque vers la RAM. Les réponses suivantes sont plus rapides tant qu’il reste chargé.

### Quick Tunnel ou Named Tunnel pour du 24/7 ?

Le **Named Tunnel** est préférable : hostname stable, credentials persistants et DNS contrôlé. Le Quick Tunnel est surtout fait pour tester rapidement.

### Que se passe-t-il si le sandbox redémarre ?

- Si le système de fichiers est conservé : `ola recover` ou la commande de démarrage `ola start` peuvent relancer les services.
- Si le sandbox est recréé depuis zéro : relance le setup complet.
- Si la plateforme s’arrête complètement : aucun watchdog interne ne peut redémarrer le sandbox lui-même.

### Comment changer de hostname ou passer de Quick à Named ?

Relance le setup et choisis le mode Named Tunnel :

```bash
ola setup
```

Le script redemandera le nom du tunnel et le hostname, puis régénérera la configuration et la route DNS.

### Comment forcer HTTP/2 pour cloudflared ?

Au setup :

```bash
CF_TUNNEL_PROTOCOL=http2 ola setup
```

ou avec le fichier téléchargé :

```bash
CF_TUNNEL_PROTOCOL=http2 ./ollama-cloudflare-setup.sh setup
```

### Comment savoir quel modèle est en RAM et lequel est sur le disque ?

- RAM : `ola ps` ;
- disque : `ola models` ou le gestionnaire interactif ;
- vue complète : `ola doctor`.

### Le modèle par défaut de `ola` s’applique-t-il à toutes les applications ?

Non. Il sert à `ola test`, au gestionnaire et aux actions `ola`. Les clients API doivent indiquer explicitement le champ `model` à chaque requête Ollama.

---

# Fichiers du dépôt

| Fichier | Description |
|---|---|
| `Install.sh` | Installeur interactif SSH + Cloudflare Tunnel / fxTunnel et pack d’outils VPS essentiels. |
| `ollama-cloudflare-setup.sh` | Installeur et gestionnaire Ollama + Cloudflare Tunnel ; devient la commande `ola` après installation. |
| `README.md` | Documentation d’installation, de configuration et d’utilisation. |

Pour la partie Ollama, les commandes à retenir sont :

```bash
ola status
ola doctor
ola test
ola models
```
