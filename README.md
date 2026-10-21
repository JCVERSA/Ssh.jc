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
  - [Google Colab](#google-colab)
  - [Quick Tunnel ou Named Tunnel](#quick-tunnel-ou-named-tunnel)
  - [Configuration](#configuration)
  - [Guide d’utilisation `ola`](#guide-dutilisation-ola)
  - [Gestion interactive des modèles](#gestion-interactive-des-modèles)
  - [Vitesse : mesurer et optimiser (Pack Speed)](#vitesse--mesurer-et-optimiser-pack-speed)
    - [Fluidité : premier token et streaming](#fluidité--premier-token-et-streaming)
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
- Node.js : le script demande la version majeure à installer (**22 LTS** ou **24 LTS**, 24 par défaut) via le dépôt apt signé de NodeSource, puis installe `nodejs` et `pm2` en global ;
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
- Les paquets/scripts distants sans checksum vérifiable ne sont pas installés automatiquement. Node.js n’exécute plus le script distant de NodeSource : le script configure son dépôt apt avec une clé dédiée (`signed-by`) et laisse apt vérifier les paquets.

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
- Une interface terminal optionnelle, **`ola tui`**, est installée automatiquement par le setup ; le moteur et toutes les commandes texte continuent de fonctionner si son installation échoue.
- Les téléchargements d’Ollama et de cloudflared sont vérifiés quand un checksum est disponible.
- Ollama est volontairement limité pour les petits sandboxes : un seul modèle chargé, une requête parallèle, une file d’attente d’au plus 10 requêtes et un contexte de 1024 tokens par défaut.
- Le même artefact fonctionne sur **VPS/sandbox Debian/Ubuntu classique** et dans **Google Colab**. Le profil Colab est explicitement activé par le notebook (`OLA_COLAB=1`) : il conserve les modèles et les petits réglages dans Google Drive et utilise le GPU NVIDIA quand Colab en fournit un. Sans ce profil, le comportement VPS/sandbox historique reste inchangé : utilisateurs système dédiés `ollama`/`cloudflared`, stockage local des modèles et aucun chemin NVIDIA Colab ajouté.

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

- **RAM : 2 Go** pour `qwen3:1.7b` et les modèles d’environ 1 à 1,5 Go ;
- **disque : au moins 5 Go libres** avant une installation complète ;
- un sandbox qui reste actif si l’objectif est une disponibilité 24/7.

À titre indicatif :

- l’archive Ollama fait environ **1,37 Go** ;
- le modèle par défaut `qwen3:1.7b` occupe environ **1,4 Go** sur le disque [1](https://ollama.com/library/qwen3:1.7b) ;
- le setup vérifie l’espace avant le téléchargement/extraction et choisit un dossier temporaire assez grand, ce qui évite le piège classique d’un `/tmp` limité à 1 Go.

Les modèles plus gros peuvent nécessiter beaucoup plus de RAM et de disque. En cas de doute, commence par un petit modèle d’environ 1 à 1,5 Go et vérifie avec `ola doctor`.

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
7. demande le modèle à télécharger (`qwen3:1.7b` si tu appuies simplement sur Entrée) ;
8. décharge d’abord, si besoin, un autre modèle déjà présent en RAM ;
9. télécharge le modèle choisi ;
10. installe cloudflared, d’abord via le dépôt apt officiel Cloudflare, puis en secours via le paquet GitHub vérifié ;
11. demande le mode de tunnel : Quick Tunnel ou Named Tunnel ;
12. démarre et vérifie le tunnel ;
13. affiche le statut final et l’URL publique.

Forme équivalente pour démarrer le setup :

```bash
./ollama-cloudflare-setup.sh setup
```

Sans argument après `setup`, le choix du modèle et du tunnel reste interactif.

#### Setup rapide avec arguments

Pour décider le modèle et le tunnel directement dans la commande :

```bash
# Modèle par défaut du projet (qwen3:1.7b) + Quick Tunnel
ola setup default

# Modèle imposé + Quick Tunnel
ola setup qwen3:0.6b 1
ola setup qwen3:0.6b quick

# Modèle imposé + Named Tunnel, hostname imposé
ola setup qwen3:1.7b 2 ollama.example.com
ola setup qwen3:1.7b account ollama.example.com
ola setup qwen3:1.7b named ollama.example.com

# Named Tunnel sans hostname : seul le hostname manquant est demandé
ola setup qwen3:1.7b 2
```

Règles :

- `ola setup <modèle>` seul est refusé : le mode tunnel est obligatoire, sauf pour le raccourci complet `ola setup default` ;
- `default` désigne toujours le modèle intégré au projet, actuellement `qwen3:1.7b`, même si un autre modèle est enregistré comme défaut sur le sandbox ;
- le mot-clé `default` peut aussi servir de modèle avec un mode explicite, par exemple `ola setup default 2 ollama.example.com` ;
- les modes acceptés sont `1` ou `quick` pour Quick Tunnel, et `2`, `account` ou `named` pour Named Tunnel ;
- en mode Named Tunnel rapide, le nom du tunnel est `ollama-vps` ; si le hostname est absent, il est demandé, et la connexion Cloudflare reste interactive si aucun certificat de connexion n’existe encore ;
- pour choisir un nom de tunnel personnalisé, utilise le setup interactif classique `ola setup`.

Ces formes rapides exécutent le **même setup complet** que la forme interactive : elles suppriment seulement les questions dont la réponse est déjà fournie. Sur un sandbox déjà configuré, elles peuvent donc régénérer les configurations et redémarrer les services.

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

## Google Colab

Le projet fournit un notebook prêt à exécuter : [`colab/Ola-Colab.ipynb`](colab/Ola-Colab.ipynb).

Ouvrir dans Colab :

```text
https://colab.research.google.com/github/JCVERSA/Ssh.jc/blob/arena/e89a71aa-ssh-jc/colab/Ola-Colab.ipynb
```

### Parcours Colab, du début à la fin

1. Dans Colab, choisis éventuellement **Exécution → Modifier le type d'exécution → GPU** (T4 si disponible). Le CPU fonctionne aussi.
2. Lance les cellules du notebook dans l'ordre.
3. La première cellule monte Google Drive et prépare `/content/drive/MyDrive/ola-colab`.
4. La deuxième cellule vérifie le runtime, télécharge `ollama-cloudflare-setup.sh`, contrôle son SHA-256 et le rend exécutable.
5. La troisième cellule lance le setup complet rapide :

   ```bash
   ./ollama-cloudflare-setup.sh setup default
   ```

   Cela installe Ollama, télécharge ou réutilise `qwen3:1.7b`, démarre les services sous Supervisor et crée un **Quick Tunnel**.
6. Le notebook exécute ensuite `ola colab status`, `ola doctor`, `ola test`, affiche l'URL publique et teste cette URL avec `/api/version`, `/api/tags` et `/api/chat`.
7. La dernière cellule sauvegarde les réglages `ola` dans Google Drive avec `ola colab save`.

Pendant la session, les commandes habituelles restent disponibles dans une cellule `%%bash` :

```bash
ola status
ola doctor
ola test
ola logs
ola recover
ola colab status
```

La TUI `ola tui` demande un vrai terminal interactif ; dans les cellules Colab, utilise les commandes texte.

### Ce que le profil Colab change — et ce qu'il ne change pas

Le notebook active explicitement :

```bash
export OLA_COLAB=1
export OLA_COLAB_STATE_DIR=/content/drive/MyDrive/ola-colab
export OLLAMA_MODELS=/content/drive/MyDrive/ola-colab/models
export LD_LIBRARY_PATH=/usr/lib64-nvidia:/usr/local/cuda/lib64:$LD_LIBRARY_PATH
```

| Sujet | VPS / sandbox classique | Google Colab (`OLA_COLAB=1`) |
|---|---|---|
| Utilisateurs des services | `ollama` et `cloudflared` dédiés | `root`, utilisateur unique du runtime et du montage Drive |
| Modèles Ollama | Stockage local par défaut | `OLLAMA_MODELS` dans Google Drive |
| GPU NVIDIA | Comportement Ollama standard de la machine | Chemin `/usr/lib64-nvidia` ajouté dans la configuration Supervisor ; repli CPU si aucun GPU |
| Réglages `ola` | `/etc/ollama-cloudflare-*` | Restaurés depuis Drive au setup, puis sauvegardés par `ola colab save` |
| Tunnel du parcours garanti | Quick ou Named selon le setup | Quick Tunnel uniquement dans le notebook |
| Persistance après arrêt | Selon le VPS/sandbox | Modèles et réglages dans Drive ; système et URL recréés |

Sans `OLA_COLAB=1`, un VPS ou un sandbox ne reçoit ni le profil root Colab, ni `OLLAMA_MODELS` forcé, ni le chemin NVIDIA Colab. Le même artefact reste donc utilisable normalement hors Colab.

### Persistance : ce qui est gardé, honnêtement

Google Drive conserve :

- les fichiers modèles Ollama, car Ollama écrit directement dans `OLLAMA_MODELS` ;
- le modèle par défaut, le mode Pack Speed et le keep-alive `ola`, copiés dans `MyDrive/ola-colab/config/` ;
- la dernière URL Quick Tunnel à titre d'historique.

Ne peuvent pas survivre à la suppression du runtime Colab :

- les binaires et paquets installés ;
- `/etc`, Supervisor et les processus ;
- l'URL Quick Tunnel : un nouveau runtime crée une nouvelle URL.

Au prochain runtime, rouvre le notebook et relance toutes les cellules : Drive est remonté, les modèles déjà présents sont réutilisés, les réglages sont restaurés et une nouvelle URL publique est générée. Colab peut aussi arrêter un runtime inactif ou arrivé en fin de durée de vie ; `ola` ne peut pas transformer Colab en hébergement 24/7.

Commandes Colab spécifiques :

| Commande | Effet |
|---|---|
| `ola colab status` | Affiche le profil actif, le dossier Drive, le dossier modèles et le GPU/CPU détecté. |
| `ola colab save` | Copie les réglages `ola` actuels vers `OLA_COLAB_STATE_DIR/config`. Root requis. |
| `ola colab restore` | Restaure ces réglages dans le runtime actuel ; relance ensuite `ola setup default` pour régénérer les services. Root requis. |

Le parcours Colab est couvert par la suite de tests isolée du dépôt (profil root, `OLLAMA_MODELS`, chemin NVIDIA, sauvegarde/restauration de l'état et notebook statique). Le runtime Google réel dépend de ton compte et de la machine attribuée par Colab : lance le notebook pour la vérification finale dans ton environnement.

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
- lancer une nouvelle version du script avec `setup`, `start`, `recover`, `use`, `unload`, `delete` ou `speed apply`/`speed reset` met aussi à jour la copie stable ;
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
OLLAMA_MAX_QUEUE="10"
HOME="/var/lib/ollama"
```

Explications :

- `OLLAMA_HOST="127.0.0.1:11434"` : Ollama reste local, il n’écoute pas directement sur toutes les interfaces ;
- `OLLAMA_ORIGINS="*"` : autorise les requêtes venant du tunnel malgré le contrôle d’origine d’Ollama ;
- le Host public est réécrit par cloudflared en `localhost:11434`, ce qui évite le second contrôle Ollama qui rejette les hostnames publics ;
- `OLLAMA_CONTEXT_LENGTH` : taille de contexte par défaut, volontairement basse pour les petits sandboxes ;
- `OLLAMA_KEEP_ALIVE="5m"` : un modèle inactif peut être déchargé après 5 minutes ; cette valeur par défaut du serveur est enregistrée dans `/etc/ollama-cloudflare-keepalive` et se change délibérément avec `ola fluid keepalive <durée|reset>` (voir [Fluidité](#fluidité--premier-token-et-streaming)) ;
- `OLLAMA_MAX_LOADED_MODELS="1"` : objectif d’un seul modèle chargé en RAM sur une nouvelle installation ;
- `OLLAMA_NUM_PARALLEL="1"` : une seule requête à la fois, plus sûr en RAM ;
- `OLLAMA_MAX_QUEUE="10"` : au plus 10 requêtes en attente derrière la requête active. Au-delà, Ollama refuse vite la requête au lieu d’accumuler des connexions et des contextes en attente sur un petit serveur exposé sans authentification.

En mode **Pack Speed** (voir [Vitesse : mesurer et optimiser](#vitesse--mesurer-et-optimiser-pack-speed)), deux variables supplémentaires sont ajoutées par `ola speed apply` :

```ini
OLLAMA_FLASH_ATTENTION="1"
OLLAMA_KV_CACHE_TYPE="q8_0"
```

Le mode choisi (`balanced` ou `speed`) est enregistré dans `/etc/ollama-cloudflare-speed` et conservé si tu relances un setup. C’est un mode **global au serveur Ollama** : il s’applique à tous les modèles servis, pas seulement au modèle par défaut de `ola`. `ola speed apply` ne modifie jamais `OLLAMA_NUM_PARALLEL`, `OLLAMA_MAX_LOADED_MODELS`, le contexte ni le keep-alive.

Ces paramètres sont écrits dans la configuration Supervisor au moment du setup. Pour les modifier proprement, ajuste les variables ci-dessous puis relance un setup, ou modifie la configuration Supervisor puis recharge-la avec `ola start`.

### Variables d’environnement utiles

Ces variables se placent **avant** la commande de setup ou la commande concernée.

| Variable | Défaut | Effet |
|---|---:|---|
| `OLLAMA_TMPDIR` | Choix automatique | Force le dossier temporaire volumineux utilisé pour l’archive Ollama et les téléchargements cloudflared de secours. Utile si `/tmp` est petit. |
| `OLLAMA_CONTEXT_LENGTH` | `1024` | Contexte Ollama écrit dans la configuration Supervisor pendant le setup. Augmenter le contexte augmente la RAM utilisée. |
| `CF_TUNNEL_PROTOCOL` | `auto` | Protocole cloudflared : `auto`, `http2` ou `quic`. Écrit dans la configuration du tunnel pendant le setup. |
| `OLA_COLAB` | `0` | `1` active le profil Google Colab. Inactif par défaut sur VPS/sandbox. |
| `OLA_COLAB_STATE_DIR` | Vide | Dossier persistant Colab, normalement `/content/drive/MyDrive/ola-colab`. |
| `OLLAMA_MODELS` | Vide | Dossier où Ollama stocke les modèles. Le notebook Colab le pointe vers Google Drive ; sur un VPS, ne le définis que si tu veux déplacer volontairement le stockage. |

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
| `/usr/local/lib/ollama-cloudflare/backup/` | Version précédente conservée par `ola update` pour le retour arrière |
| `/usr/local/lib/ollama-cloudflare/ola_tui.py` | Application Textual extraite depuis l’artefact unique |
| `/usr/local/lib/ollama-cloudflare/tui-requirements.txt` | Versions Python/Textual épinglées pour la TUI |
| `/usr/local/lib/ollama-cloudflare/tui-venv/` | Environnement Python isolé de la TUI, créé par le setup ou `ola tui install` |
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
| `/etc/ollama-cloudflare-speed` | Mode vitesse enregistré : `balanced` ou `speed` (Pack Speed) |
| `/etc/ollama-cloudflare-keepalive` | Keep-alive par défaut du serveur Ollama enregistré (absent = `5m`), modifié par `ola fluid keepalive` |
| `/etc/ollama-cloudflare-colab` | Marqueur du profil Colab dans le runtime actuel et chemin de l’état Drive (Colab uniquement) |
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
ola bench
ola bench <modèle>
ola speed
ola speed apply
ola speed reset
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
- `speed apply`, `speed reset` ;
- dans le gestionnaire `ola models`, les actions `u`, `d`, `l` et `a`.

Les commandes suivantes sont en lecture seule :

- `status`, `doctor`, `test`, `speed` (état), `ps`, `logs`, `watchdog` ;
- `ola models` en affichage simple, ou en mode lecture seule si tu n’es pas root.

Cas particulier : `ola bench` ne modifie ni la configuration ni les fichiers des modèles, mais il peut charger et décharger des modèles en RAM pour les tester un par un.

En root, lance-les simplement. Depuis un utilisateur administrateur, utilise `sudo ola ...` pour les commandes d’écriture.

### Référence des commandes

| Commande | Description |
|---|---|
| `ola` | Ouvre le menu interactif. |
| `ola help` ou `ola --help` | Affiche l’aide courte. |
| `ola setup` | Lance ou relance l’installation complète interactive et régénère les configurations. |
| `ola setup default` | Setup complet rapide avec le modèle intégré par défaut (`qwen3:1.7b`) et un Quick Tunnel. |
| `ola setup <modèle> <1\|quick\|2\|account\|named> [hostname]` | Setup complet sans les questions modèle/tunnel ; le hostname optionnel n’est accepté qu’en mode Named Tunnel. |
| `ola status` | Affiche Supervisor, l’API locale, les modèles connus et l’URL publique enregistrée. |
| `ola doctor` | Diagnostic complet : binaires, Supervisor, services, API, modèles, tunnel, RAM, disque, logs et URL publique. |
| `ola test` | Teste l’API locale, vérifie le modèle par défaut, fait une mini-conversation et teste l’URL publique. |
| `ola update` | Met à jour le gestionnaire `ola` et les fichiers de la TUI depuis la version publiée sur GitHub : vérification SHA-256, sauvegarde de l’ancienne version, installation atomique, redémarrage des services et retour arrière si le redémarrage ou l’API échoue. Root requis. |
| `ola colab status` | Affiche le profil Colab/VPS, l’état Google Drive, le dossier modèles et le GPU/CPU. Lecture seule. |
| `ola colab save` | Sauvegarde les réglages `ola` dans l’état Colab Google Drive. Root requis. |
| `ola colab restore` | Restaure les réglages `ola` depuis l’état Colab. Root requis. |
| `ola bench` | Sans argument (ou `ola bench all`), mesure **tous les modèles téléchargés présents**, un par un : même question courte avec thinking par défaut puis `think:false`, tok/s, verdict par modèle et synthèse globale. Le modèle par défaut est testé en dernier. |
| `ola bench <modèle>` | Mesure uniquement le modèle indiqué. |
| `ola speed` | Affiche le mode vitesse global du serveur Ollama, la liste des modèles présents concernés, la configuration effective, le CPU (AVX/AVX2, cœurs), la RAM et les recommandations. Lecture seule. |
| `ola speed apply` | Active le Pack Speed pour **tout le serveur Ollama** : mesure chaque modèle présent avant, active Flash Attention + cache KV `q8_0`, redémarre Ollama seul, puis vérifie et mesure chaque modèle présent après. Retour arrière automatique si un modèle qui fonctionnait ne répond plus. Root requis. |
| `ola speed reset` | Désactive le Pack Speed pour tout le serveur et restaure la configuration équilibrée, avec mesure/vérification de chaque modèle présent. Root requis. |
| `ola bench --stream` | Mesure la **fluidité** de tous les modèles présents, un par un : temps avant le 1er token visible (TTFT) et régularité du flux, en local et via l’URL publique enregistrée si elle est joignable, avec synthèse. Alias : `ola fluid bench`. |
| `ola bench --stream <modèle>` | Mesure la fluidité uniquement pour le modèle indiqué. |
| `ola fluid` | Affiche l’état fluidité : keep-alive enregistré et effectif, modèles présents, modèle chargé en RAM avec sa taille et son expiration, RAM/swap et actions disponibles. Lecture seule. |
| `ola fluid warm [modèle]` | Charge un seul modèle (le défaut de `ola` si non précisé) et le garde chaud pour la session (keep-alive 30 min par requête, ou le keep-alive serveur s’il a été rallongé). Libère les autres modèles d’abord. |
| `ola fluid preset [modèle]` | Affiche un preset de requête stable et rapide à copier dans ton client (`stream:true`, `think:false` seulement si le modèle déclare la capacité thinking, `num_ctx`/`num_thread` fixes, keep-alive de session). Lecture seule. |
| `ola fluid keepalive <durée>` | Change le keep-alive par défaut du serveur (`OLLAMA_KEEP_ALIVE`) pour toutes les requêtes qui ne le précisent pas, par ex. `30m`, `1h`, `2h30m`, `3600` ou `-1`. Enregistré dans `/etc/ollama-cloudflare-keepalive`, vérification de l’API et du modèle, retour arrière automatique. Root requis. |
| `ola fluid keepalive reset` | Restaure le keep-alive par défaut du serveur : `5m`. Root requis. |
| `ola tui` | Ouvre l’interface plein écran Textual : tableau de bord et modèles en direct, fraîcheur des données, détail du modèle, actions modèles, preset/bench, journaux recherchables avec suivi et thèmes persistés. Terminal interactif requis. |
| `ola tui install` | Installe ou répare l’environnement Python/Textual isolé de la TUI. Root et accès PyPI requis. |
| `ola tui status` | Indique si l’application TUI et son environnement Textual sont prêts. Lecture seule. |
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
 1) qwen3:1.7b                        1.4 GB [défaut] [RAM]
 2) llama3.2:1b                       1.3 GB
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
ola use llama3.2:1b
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
ola use qwen3:1.7b
ola use llama3.2:1b
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
qwen3:1.7b
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
qwen3:1.7b
llama3.2:1b
```

### `ola delete` : supprimer définitivement un modèle du disque

Supprimer un modèle :

```bash
ola delete llama3.2:1b
```

Alias :

```bash
ola rm llama3.2:1b
```

Comportement :

1. vérifie que le modèle existe sur le disque ;
2. le décharge d’abord de la RAM s’il y est ;
3. envoie la suppression à l’API Ollama ;
4. vérifie qu’il a disparu de la liste des modèles téléchargés.

#### Protection du modèle par défaut

La suppression du modèle par défaut est refusée sans `--force`, pour éviter de laisser `ola test` sans modèle valide :

```bash
ola delete qwen3:1.7b
```

Message attendu : il faut d’abord changer de modèle ou forcer.

Changement propre recommandé :

```bash
ola use llama3.2:1b
ola delete qwen3:1.7b
```

Suppression forcée :

```bash
ola delete qwen3:1.7b --force
```

Si d’autres modèles restent, le premier modèle restant devient le nouveau défaut. Si aucun modèle ne reste, le fichier de défaut est retiré et il faudra installer un modèle avec `ola use <modèle>`.

Différence essentielle :

- `ola unload` = libère la RAM, conserve le modèle sur le disque ;
- `ola delete` = libère la RAM si besoin **et supprime définitivement les fichiers du modèle**.

## Vitesse : mesurer et optimiser (Pack Speed)

Sur un petit sandbox CPU d’environ 2 Go de RAM, la vitesse dépend surtout du modèle, du CPU et de la façon dont les requêtes sont envoyées. Le Pack Speed suit un principe simple : **mesurer d’abord, ne changer que ce qui est sûr, et pouvoir revenir en arrière**.

**Portée globale :** le Pack Speed n’est pas un réglage par modèle et n’est pas limité à Qwen. Les réglages serveur (`OLLAMA_FLASH_ATTENTION`, `OLLAMA_KV_CACHE_TYPE`, contexte, parallélisme) vivent dans le processus Ollama et s’appliquent à tous les modèles qu’il sert. Les mesures et vérifications prennent en compte **tous les modèles téléchargés présents au moment de la commande**, quel que soit leur nom ou leur famille. Si tu installes un autre modèle plus tard, il bénéficie du même mode serveur, et le prochain `ola bench` le prendra en compte.

### Mesurer avec `ola bench`

```bash
ola bench
ola bench all
ola bench <modèle>
```

Sans nom de modèle, `ola bench` teste **tous les modèles présents sur le disque**, un par un. Avant le test d’un modèle, les autres modèles) :

1. avec le thinking par défaut ;
2. avec `"think": false`.

Il affiche pour chaque run le temps total, le temps de chargement, la vitesse du prompt et la vitesse de génération en tokens/seconde, puis un verdict propre à ce modèle. Quand Ollama rapporte le nombre de tokens de prompt lus depuis son cache (`prompt_eval_cached_count`), la vitesse de prompt affichée est celle du **prompt non caché** (les tokens en cache sont exclus du calcul, car les versions récentes d’Ollama ne chronomètrent que la partie non cachée) ; le nombre de tokens en cache est affiché à côté. À la fin, une **synthèse globale** compare les modèles présents. Le premier run d’un modèle peut inclure son chargement en RAM ; relance `ola bench` pour comparer à chaud.

Un modèle peut refuser `think:false` s’il n’a pas de mode réflexion : le bench le signale pour ce modèle précis et continue avec les autres. Si un run échoue, la synthèse le marque sans empêcher les autres modèles d’être testés.

Si un modèle met du temps à sortir de la RAM (runner encore occupé à terminer une requête), la demande de déchargement `keep_alive: 0` est renvoyée plusieurs fois pendant environ 30 secondes. Si le modèle reste malgré tout chargé, le bench avertit et continue la séquence en demandant le modèle suivant à Ollama (le serveur reste limité à un modèle chargé) au lieu d’abandonner tous les modèles restants. Les opérations strictes (`ola use`, `ola delete`, setup) gardent en revanche le blocage : elles exigent que le déchargement soit confirmé.

`ola bench` ne change ni la configuration ni les fichiers des modèles, mais il peut charger/décharger des modèles en RAM pendant la séquence.

### Voir l’état avec `ola speed`

```bash
ola speed
```

Affiche :

- le mode enregistré : `balanced` (défaut) ou `speed` ;
- la liste des modèles téléchargés présents concernés par ce mode global, avec le modèle par défaut marqué ;
- la configuration Ollama réellement écrite dans Supervisor (Flash Attention, cache KV, contexte, keep-alive, parallélisme) ;
- le CPU : cœurs logiques/physiques estimés et présence d’AVX/AVX2/AVX-512 (AVX2 donne le meilleur backend CPU d’Ollama) ;
- la RAM disponible et le ou les modèles chargés ;
- les recommandations d’usage.

`ola doctor` affiche aussi une ligne résumant le mode vitesse.

### Activer le Pack Speed

```bash
ola speed apply
```

Ce que fait la commande, dans l’ordre :

1. inventorie tous les modèles téléchargés présents et mesure leur vitesse actuelle, **un modèle à la fois** (test court `think:false`, avec repli sur le comportement par défaut du modèle si `think:false` est refusé) ;
2. enregistre le mode `speed` dans `/etc/ollama-cloudflare-speed` ;
3. ajoute uniquement ces deux réglages à la configuration Supervisor du **serveur Ollama entier** :
   - `OLLAMA_FLASH_ATTENTION="1"` : attention plus efficace quand le modèle et le CPU la supportent ;
   - `OLLAMA_KV_CACHE_TYPE="q8_0"` : cache KV environ deux fois plus léger que le `f16` par défaut, ce qui libère de la RAM et peut aider la vitesse ;
4. recharge Supervisor et redémarre **Ollama seul** (le tunnel n’est pas redémarré) ;
5. vérifie qu’Ollama répond, puis reteste **chaque modèle présent**, un par un, avec une comparaison avant/après par modèle ;
6. affiche combien de modèles présents ont passé la vérification.

Si Ollama ne revient pas, ou si un modèle qui répondait avant le changement ne répond plus après, la commande **restaure automatiquement l’ancienne configuration** et l’ancien mode, puis redémarre Ollama : tu ne restes pas avec un réglage cassé. Un modèle qui ne répondait déjà pas avant le changement est signalé, mais ne déclenche pas à lui seul le retour arrière.

Pendant ces mesures un par un, si un modèle tarde à se décharger de la RAM, la séquence réessaie puis continue avec le modèle suivant (même comportement que `ola bench`) au lieu d’abandonner toute la commande avant même le changement de configuration.

Ce que `ola speed apply` ne change **jamais** :

- `OLLAMA_NUM_PARALLEL="1"` : augmenter le parallélisme ne rend pas une requête seule plus rapide et consomme plus de RAM ;
- `OLLAMA_MAX_LOADED_MODELS="1"` : un seul modèle en RAM ;
- le contexte (`1024`) : un contexte plus grand coûte de la RAM ;
- le keep-alive : Pack Speed ne le touche pas ; il se règle séparément et délibérément avec `ola fluid keepalive` (défaut `5m`).

Relancer `ola speed apply` alors que le mode est déjà actif ne réécrit pas la configuration et ne redémarre pas Ollama (détection « already set ») ; en revanche, la commande relance un bench global de contrôle afin d’inclure aussi les modèles ajoutés depuis. Même logique pour `ola speed reset` si le mode équilibré est déjà actif. Un nouveau setup conserve le mode enregistré.

### Revenir en arrière

```bash
ola speed reset
```

Restaure la configuration équilibrée du serveur entier (sans Flash Attention ni cache KV quantifié), avec la même mesure et la même vérification automatique pour chaque modèle présent.

### Optimiser côté client

Les gains les plus importants se jouent souvent dans la requête envoyée par ton application, pas dans le serveur :

- **questions simples** : envoie `"think": false` pour les modèles à réflexion qui le supportent — Qwen3, mais aussi tout autre modèle de ce type (c’est ce que `ola bench` mesure modèle par modèle) ; les modèles sans réflexion peuvent refuser ce champ, dans ce cas ne l’envoie pas pour eux ;
- **affichage progressif** : envoie `"stream": true` ; la génération n’est pas plus rapide, mais les tokens arrivent au fur et à mesure au lieu d’attendre la fin ;
- **réponses bornées** : `options.num_predict` (par exemple `128` ou `256`) évite les réponses inutilement longues ;
- **threads** : `options.num_thread` proche du nombre de cœurs physiques (affiché par `ola speed`) peut aider ; teste et compare ;
- **`options.num_batch`** : n’a d’intérêt sensible que pour les très longs prompts ;
- **une seule chose à la fois** : garde un seul modèle chargé (`ola ps`, `ola unload`) sur un petit sandbox.

Exemple de requête rapide :

```bash
curl -fsS https://ton-hostname.example/api/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3:1.7b",
    "messages": [
      {"role": "user", "content": "Dis bonjour en une phrase."}
    ],
    "stream": true,
    "think": false,
    "options": {"num_predict": 128}
  }'
```

Le keep-alive de 5 minutes est un compromis : le modèle reste en RAM pour des réponses suivantes rapides, puis la RAM est libérée. `ola unload` force la libération immédiate si tu as besoin de RAM pour autre chose.

### Fluidité : premier token et streaming

La vitesse de génération (tok/s) n’est pas ce que l’on ressent en premier. Ce qui se ressent, c’est :

1. **le délai avant le premier token visible** (TTFT) : chargement du modèle s’il n’est pas en RAM, évaluation du prompt, puis premier morceau de réponse ;
2. **la régularité du flux ensuite** : les tokens arrivent-ils au fur et à mesure, ou par paquets après de longs silences ?

Le Pack Fluidité mesure ces deux choses au lieu de les supposer, et donne les leviers sûrs pour les améliorer sur un petit sandbox. Il ne change ni le nombre de modèles chargés, ni le parallélisme, ni le contexte.

#### Mesurer la fluidité : `ola bench --stream`

```bash
ola bench --stream            # tous les modèles présents, un par un
ola bench --stream <modèle>   # un seul modèle
ola fluid bench               # alias
```

Pour chaque modèle présent, la commande envoie la même question courte en `stream:true` (preset stable : `num_ctx 1024`, `num_thread` = cœurs physiques estimés, 48 tokens max, température 0, d’abord avec `think:false` puis, si le modèle le refuse, avec son comportement par défaut). Elle affiche :

- **1er token visible** : délai avant le premier morceau de réponse visible ; le contenu `thinking` caché ne compte pas, donc un modèle qui « réfléchit » longtemps avant d’écrire affiche son vrai délai ressenti ;
- le temps total, le temps de chargement du modèle, la vitesse de génération ;
- la vitesse du **prompt non caché** : Ollama met les compteurs dans le dernier morceau du flux (`total_duration`, `load_duration`, `prompt_eval_count`, `prompt_eval_cached_count`, `prompt_eval_duration`, `eval_count`, `eval_duration`, en nanosecondes) ; depuis Ollama 0.33.3, `prompt_eval_duration` ne chronomètre que les tokens de prompt **non** lus depuis le cache du prompt, donc `ola` soustrait d’abord les tokens en cache avant de calculer des tok/s — sinon, répéter le même prompt afficherait une vitesse de prompt gonflée par le cache. Le bench classique `ola bench` applique la même correction quand Ollama rapporte le compteur de cache ;
- le **plus grand trou** entre deux morceaux visibles et le nombre de morceaux : c’est la mesure de régularité.

Si une URL publique est enregistrée et joignable depuis le sandbox, la même mesure est refaite **à travers le tunnel** et comparée au local dans la synthèse. Si le sandbox ne résout pas son propre hostname public (déjà observé sur ce type d’hébergement alors que le tunnel répondait depuis l’extérieur), la mesure publique est ignorée avec un avertissement explicite : le TTFT public se mesure alors depuis ton client réel. C’est indispensable : la documentation Cloudflare indique que le trafic proxifié est bufferisé par défaut sauf si l’origine répond avec `Content-Type: text/event-stream`, alors qu’Ollama streame en JSON ligne par ligne (`application/x-ndjson`). Le chemin public peut donc, selon le client et le réseau, ne pas restituer le flux au fur et à mesure — seule la comparaison TTFT local/public le montre. Si le TTFT public est très supérieur au TTFT local ou si les morceaux publics arrivent par paquets, le problème est le chemin public (tunnel/client), pas le modèle ni le serveur.

Les requêtes de ce bench gardent le modèle testé chaud 30 minutes (`keep_alive`) : enchaîner avec tes vraies questions juste après profite donc d’un modèle déjà chargé. `ola bench --stream` ne change aucune configuration et ne modifie aucun fichier de modèle ; il peut charger/décharger des modèles en RAM pendant la séquence, comme `ola bench`.

#### Voir l’état : `ola fluid`

```bash
ola fluid
```

Affiche le keep-alive enregistré (`/etc/ollama-cloudflare-keepalive`) et celui réellement écrit dans Supervisor, les modèles présents, le modèle chargé en RAM avec la taille qu’il occupe, son expiration keep-alive et le contexte chargé (données de `/api/ps`), la RAM et le swap libres, l’URL publique enregistrée, et les actions fluidité disponibles. `ola doctor` affiche aussi une ligne « Fluid keep-alive ».

#### Garder un modèle chaud pour une session : `ola fluid warm`

```bash
ola fluid warm              # modèle par défaut de ola
ola fluid warm <modèle>
```

Décharge d’abord les autres modèles, charge le modèle choisi avec une micro-requête, et le garde en RAM pour la session : le keep-alive envoyé vaut 30 minutes (ou le keep-alive serveur si tu l’as rallongé avec `ola fluid keepalive`). Les requêtes suivantes démarrent alors sans temps de chargement. C’est un préchauffage par session, pas un réglage permanent : après la session, `ola unload` libère la RAM. Ollama garde par défaut un modèle 5 minutes après sa dernière requête ; chaque nouvelle requête relance ce délai.

#### Preset stable à envoyer à chaque requête : `ola fluid preset`

```bash
ola fluid preset [modèle]
```

Affiche un corps de requête complet à copier dans ton client, adapté au modèle : `stream:true`, keep-alive de session, `num_ctx` et `num_thread` fixes, et `"think": false` **uniquement si le modèle déclare la capacité `thinking`** (lue via `/api/show`) — pour un modèle sans réflexion, la ligne est omise au lieu d’être refusée. Réutilise ce preset **tel quel à chaque requête de la session** :

- changer `num_ctx` (ou certains réglages du runner comme `num_thread`) entre deux requêtes peut forcer Ollama à recharger le modèle : c’est un temps de chargement complet payé en plein milieu d’une conversation ;
- garde le même début de prompt (même system prompt, historique dans le même ordre) : Ollama réutilise le cache du prompt pour la partie inchangée, et seuls les nouveaux tokens sont évalués — c’est visible dans le compteur « prompt non caché » des benchs ;
- limite `num_predict` au besoin réel et évite de changer de modèle au milieu d’une session.

#### Changer le keep-alive par défaut du serveur : `ola fluid keepalive`

```bash
ola fluid keepalive 30m     # ou 1h, 2h30m, 3600 (secondes), -1 (toujours chargé)
ola fluid keepalive reset   # retour à 5m
```

Par défaut, Ollama décharge un modèle inactif après 5 minutes (`OLLAMA_KEEP_ALIVE="5m"`) : la requête suivante repaye le chargement. Rallonger cette valeur rend les retours de session plus fluides, mais le modèle occupe sa RAM entre-temps — sur un sandbox d’environ 2 Go, `qwen3:1.7b` chargé ne laissait qu’environ 378 Mo disponibles dans les mesures ci-dessous. `-1` garde le modèle chargé jusqu’à `ola unload`, `ola use <autre modèle>` ou l’arrêt d’Ollama : à réserver à une session de travail surveillée.

La commande (root) enregistre la valeur dans `/etc/ollama-cloudflare-keepalive`, régénère la configuration Supervisor en **conservant le mode Pack Speed actuel**, redémarre Ollama seul, puis vérifie l’API et un modèle présent ; si la vérification échoue, l’ancienne configuration et l’ancienne valeur sont restaurées automatiquement. Un nouveau setup conserve la valeur enregistrée. Astuce intermédiaire : un client peut aussi envoyer `"keep_alive": "30m"` dans une seule requête pour garder le modèle chaud sans changer le défaut du serveur — c’est ce que font `ola fluid warm` et le preset.

#### Compromis RAM, honnêtement

- Le keep-alive ne rend **pas** la génération plus rapide : il supprime seulement le rechargement entre deux requêtes. La vitesse une fois le modèle chaud reste celle mesurée par `ola bench`.
- Plus le keep-alive est long, plus la RAM reste occupée longtemps ; avec un seul modèle chargé (`OLLAMA_MAX_LOADED_MODELS="1"`), charger un autre modèle décharge de toute façon le précédent.
- Si le swap se remplit pendant une génération, les réponses deviennent saccadées : `ola fluid` affiche le swap libre, et garder un contexte à `1024` avec un seul modèle chargé reste le réglage sûr.

### Résultats mesurés sur un petit sandbox

Mesures de référence obtenues avec `ola bench` et `ola speed apply` sur un sandbox d’environ 2 Go de RAM, 2 vCPU avec AVX-512 détecté, Ollama `0.40.6`, modèle `qwen3:1.7b` et contexte `1024`. Test : même question courte, 48 tokens maximum, température 0. Au moment de ces mesures, `qwen3:1.7b` était le seul modèle présent sur ce sandbox : ces chiffres sont donc une référence pour **ce modèle précis**, pas une promesse pour les autres. Depuis, `ola bench` sans argument teste tous les modèles présents et donne à chacun son verdict ; ne transpose pas les tok/s d’un modèle à un autre.

| Configuration | Run | Temps total | Chargement | Génération | Tokens générés | Réponse visible |
|---|---|---:|---:|---:|---:|---|
| `balanced`, modèle pas encore chargé | Thinking par défaut | 9,3 s | 5,1 s | 12,6 tok/s | 48 | **vide** |
| `balanced`, premier run suivant | `think:false` | 3,6 s | 0,0 s | 12,7 tok/s | 43 | oui |
| `speed`, modèle déjà chargé | Thinking par défaut | 3,5 s | 0,0 s | 14,1 tok/s | 48 | **vide** |
| `speed`, modèle déjà chargé | `think:false` | 2,9 s | 0,0 s | 14,4 tok/s | 40 | oui |

La mesure intégrée à `ola speed apply` a donné, sur son test court : **15,1 tok/s avant** puis **13,7 tok/s après**. Le bench complet suivant, à chaud, a mesuré **14,4 tok/s** en mode `speed`. Ces valeurs courtes varient sensiblement d’un run à l’autre.

#### Bench global réel : 3 modèles présents

Plus tard, le même sandbox contenait trois modèles et `ola bench` les a testés un par un (le modèle par défaut de ce run était `qwen3:0.6b`, donc testé en dernier) :

| Modèle | Thinking par défaut | `think:false` | Génération `think:false` | Lecture |
|---|---:|---:|---:|---|
| `qwen2.5-coder:1.5b` | 5,6 s (chargement 3,3 s) | 1,5 s | 18,0 tok/s | le verdict « ~73 % » inclut le chargement initial |
| `qwen3:1.7b` | 7,0 s, réponse vide | 3,2 s | 14,5 tok/s | le thinking a consommé les 48 tokens |
| `qwen3:0.6b` | 2,6 s, réponse vide | 1,1 s | 39,8 tok/s | environ 2,7× la génération de `qwen3:1.7b` sur ce test |

Dans ce bench global, la vitesse brute de génération classait donc : `qwen3:0.6b` (~39,8 tok/s) > `qwen2.5-coder:1.5b` (~18,0 tok/s) > `qwen3:1.7b` (~14,5 tok/s). Le bench mesure la vitesse, pas la qualité des réponses : choisis le modèle selon les deux.

#### `ola speed apply` global réel : vérification 3/3

Après le correctif de déchargement résilient, `ola speed apply` a ensuite été relancé sur ces trois mêmes modèles. Chaque modèle a été mesuré avant, déchargé, puis remesuré après l’activation du mode `speed` :

| Modèle | Avant | Après | Écart sur ce run unique |
|---|---:|---:|---:|
| `qwen2.5-coder:1.5b` | 16,6 tok/s | 18,2 tok/s | +9,6 % |
| `qwen3:1.7b` | 14,2 tok/s | 14,8 tok/s | +4,2 % |
| `qwen3:0.6b` | 39,3 tok/s | 39,4 tok/s | +0,3 % |

Résultat : **vérification réussie pour 3/3 modèles présents**, aucun retour arrière, et mode `speed` actif pour tout le serveur Ollama. Le déchargement de `qwen2.5-coder:1.5b`, qui avait bloqué le premier essai, est passé cette fois.

Ces écarts positifs restent modestes et ne reposent que sur un seul test court par modèle : ils ne suffisent pas à attribuer un gain précis à Flash Attention ou au cache KV `q8_0`. Le résultat solidement démontré ici est la **couverture globale sans régression mesurée sur ce run** ; pour prouver un gain modèle par modèle, il faudrait répéter plusieurs benchs à chaud en `balanced` puis en `speed`.

#### Bench streaming réel : le chargement domine, le tunnel suit

Le même sandbox a ensuite exécuté `ola bench --stream` sur les trois modèles. Chaque run local démarrait avec le modèle concerné non chargé ; le run public suivait immédiatement avec le même modèle gardé chaud (`keep_alive 30m`). Les deux chemins ne sont donc pas comparés à froid dans les mêmes conditions, mais le run public vérifie si le flux reste progressif après le démarrage.

| Modèle | TTFT local à froid | Chargement local | Génération locale | TTFT public à chaud | Génération publique | Plus grand trou public |
|---|---:|---:|---:|---:|---:|---:|
| `qwen2.5-coder:1.5b` | 4,1 s | 3,6 s | 14,7 tok/s | 0,1 s | 14,1 tok/s | 0,1 s |
| `qwen3:1.7b` | 3,1 s | 2,8 s | 13,2 tok/s | 0,1 s | 13,6 tok/s | 0,1 s |
| `qwen3:0.6b` | 1,7 s | 1,5 s | 33,5 tok/s | 0,1 s | 33,1 tok/s | 0,0 s |

Lecture mesurée : sur ce run, **le délai avant le premier token visible venait surtout du chargement du modèle**, pas du tunnel. Une fois le modèle chaud, le premier morceau public arrivait en environ 0,1 s et les morceaux restaient réguliers (trous ≤ 0,1 s). Cela ne prouve pas que chaque client externe aura le même comportement, mais cela innocente le chemin public testé ici : pour améliorer le ressenti sur ce sandbox, les leviers prioritaires sont `ola fluid warm`, un modèle gardé chaud pendant la session et, si la qualité suffit, un modèle plus petit comme `qwen3:0.6b`.

Interprétation honnête :

- **Le gain clairement démontré vient de `think:false`, pas d’une génération brute plus rapide.** La génération reste autour de 12,6 à 14,4 tok/s dans ces tests ; `think:false` supprime surtout les tokens de réflexion invisibles, donc la réponse utile arrive plus tôt.
- **Une réponse peut être vide si le thinking consomme tout le budget de tokens.** Dans les deux runs avec thinking par défaut, les 48 tokens ont été utilisés avant la réponse visible. Pour une question simple, utilise `think:false` ; si tu gardes le thinking, prévois un `options.num_predict` nettement plus large.
- Le premier verdict de `ola bench` affichait environ 61 % plus rapide pour `think:false`, mais ce run incluait aussi 5,1 s de chargement du modèle. À chaud, le même bench affichait environ 18 %. Compare donc plutôt des benchs à chaud, dans la même configuration.
- **Le gain de Flash Attention + cache KV `q8_0` n’est pas démontré sur ces prompts courts.** Le cache KV est alors très petit ; l’intérêt principal du `q8_0` est de réduire la RAM du cache quand les conversations et le contexte grandissent. Le mode `speed` peut être conservé s’il reste stable, et `ola speed reset` permet de revenir en arrière.
- La RAM disponible est passée d’environ 1799 Mo (modèle non chargé) à environ 378–379 Mo (modèle chargé). Cette baisse correspond principalement au chargement normal de `qwen3:1.7b`, pas au Pack Speed.

Pour reproduire une comparaison serveur plus propre :

```bash
ola bench          # attendre que le modèle soit chaud, noter le run think:false
ola speed reset
ola bench          # comparer le run think:false à chaud
ola speed apply
ola bench          # comparer à nouveau ; répéter si les écarts sont faibles
```

### Limites honnêtes

- Aucun réglage ne promet un gain précis : l’effet de Flash Attention et du cache `q8_0` dépend du modèle, du CPU et de la version d’Ollama ; c’est pour cela que `ola speed apply` mesure avant/après au lieu de promettre un chiffre. Sur le sandbox de référence ci-dessus, les écarts `speed` observés sur prompts courts sont faibles ou variables ; aucun gain précis et reproductible n’a encore été démontré.
- La qualité peut très légèrement varier avec un cache KV quantifié ; `q8_0` est le réglage prudent (le `q4_0`, plus agressif, n’est pas utilisé ici).
- Si le modèle ne supporte pas le mode réflexion, `think:false` peut être refusé : `ola bench` te le signale et il suffit d’ignorer ce réglage pour ce modèle.
- Le levier le plus radical reste un modèle plus petit, par exemple `ola use qwen3:0.6b` (environ 523 Mo) si la qualité suffit.

## Interface TUI `ola tui`

`ola tui` ouvre une interface terminal plein écran construite avec **Textual**, dans l’esprit de wifit3 : état visible en un coup d’œil, tableau mis à jour en direct, navigation au clavier, panneau de détail et barre de touches. Le moteur reste le programme Bash `ola` : la TUI lit l’API Ollama locale et délègue les actions aux commandes `ola` existantes, au lieu de réimplémenter leurs sécurités.

### Lancer et réparer

```bash
ola tui
ola tui status
sudo ola tui install
```

Le setup installe automatiquement l’environnement TUI dans un environnement Python isolé :

```text
/usr/local/lib/ollama-cloudflare/ola_tui.py
/usr/local/lib/ollama-cloudflare/tui-requirements.txt
/usr/local/lib/ollama-cloudflare/tui-venv/
```

Il faut Python 3.11 ou plus, le paquet système `python3-venv` si la création du venv le demande, et un accès à PyPI pendant l’installation. Les versions Python sont épinglées dans `tui-requirements.txt` (Textual `8.2.8` au moment de l’introduction), avec les empreintes SHA-256 des wheels PyPI : l’installation utilise `pip --require-hashes`, donc un paquet modifié ou remplacé est refusé. L’environnement de référence occupait environ 47 Mo.

Si l’installation de la TUI échoue, le setup continue et toutes les commandes classiques restent disponibles. `ola doctor` signale alors la TUI comme un avertissement, pas comme une panne du moteur. `sudo ola tui install` permet de réessayer sans refaire tout le setup.

### Écran principal

L’écran affiche :

- l’état de l’API Ollama et, sur une ligne compacte, les états Supervisor `Ollama`, `Tunnel` et `Watchdog` quand ils sont exposés ;
- l’URL publique enregistrée, suivie de l’avertissement **« API non authentifiée — garde cette URL privée »**, le mode Pack Speed et le keep-alive ;
- la RAM libre et son pourcentage **utilisé** (la barre représente la RAM utilisée), le swap et le niveau d’accès (root ou non-root) ;
- un tableau actualisé des modèles : état disque/RAM, taille, modèle par défaut, expiration keep-alive relative (`dans 4 min 05 s`, `dans 2 h 10`, etc.) et contexte chargé ;
- un détail du modèle sélectionné : état, caractère par défaut, expiration relative complétée par la date et l’heure locales, paramètres, famille, quantification et capacités déclarées par `/api/show`.

Le tableau se rafraîchit périodiquement. La barre d’état indique l’âge des données (`mis à jour il y a … s`) et signale des données anciennes après quelques secondes sans actualisation réussie. Si l’API locale ne répond plus, le panneau et la barre d’état donnent la marche à suivre : quitter avec `q`, lancer `ola start`, puis `ola doctor` ; la touche `g` ouvre les journaux. Les flèches haut/bas changent de modèle. Au premier affichage, le modèle déjà chargé en RAM est sélectionné en priorité, sinon le modèle par défaut. S’il n’y a aucun modèle, le tableau et le panneau de détail affichent explicitement l’état vide et proposent la touche `a` pour en ajouter un.

Le détail technique `/api/show` est mis en cache par nom de modèle **et par digest** : si un modèle du même nom est retéléchargé avec un contenu différent, la TUI relit son détail au lieu de réutiliser l’ancien ; les entrées des modèles qui n’existent plus sont supprimées du cache.

L’affichage s’adapte à la taille du terminal : mode standard à partir d’environ 95 colonnes ou 29 lignes, mode compact en dessous (bannière masquée, panneaux réduits, noms de modèles raccourcis au milieu), puis mode minimal sur très petit terminal (panneaux masqués pour conserver un tableau utilisable). Les confirmations gardent aussi leurs boutons visibles sur petit écran.

### Touches

| Touche | Action |
|---|---|
| `↑` / `↓` | Choisir un modèle |
| `m` | Ouvrir le menu d’actions du modèle sélectionné |
| `?` | Ouvrir l’aide complète |
| `u` | Utiliser le modèle sélectionné (confirmation) |
| `d` | Supprimer définitivement le modèle sélectionné du disque (confirmation renforcée si c’est le défaut) |
| `l` | Libérer le modèle sélectionné de la RAM (confirmation s’il est chargé) |
| `a` | Ajouter et utiliser un modèle (saisie du nom) |
| `w` | Préchauffer le modèle (`ola fluid warm`, confirmation si la RAM va changer) |
| `p` | Afficher son preset fluidité |
| `b` | Benchmark classique du modèle (confirmation) |
| `B` | Benchmark streaming du modèle (confirmation) |
| `s` | Afficher `ola speed` |
| `f` | Afficher `ola fluid` |
| `g` | Ouvrir les journaux Supervisor (`1` à `5` : fichier, `/` : recherche, `Entrée` puis `n`/`N` : résultats, `f` : suivi automatique, `r`, `q`) |
| `t` | Changer de thème parmi `textual-dark`, `nord` et `textual-light` ; le choix est mémorisé |
| `C` (Maj+C) | Copier le texte de l’écran courant : sur l’écran principal, résumé + modèles + détails + statut ; dans les journaux, la sélection si elle existe sinon le journal affiché ; dans une sortie d’action, la sortie complète. Dans un champ de saisie, Maj+C continue de taper « C ». |
| `r` | Rafraîchir maintenant |
| `q` | Quitter ou fermer l’écran courant |

Les actions longues ouvrent immédiatement un écran d’exécution : la sortie de `ola` y défile en direct, avec le temps écoulé. Pendant l’exécution, `q` ou `Ctrl+C` demande l’annulation du processus (le CLI et ses sous-processus sont arrêtés proprement) ; une fois l’action terminée ou annulée, `q` ferme l’écran. La suppression demande une confirmation dans la TUI, mais pas de mot à taper. Dans toutes les confirmations, le focus initial est placé sur **Annuler** : appuyer immédiatement sur `Entrée` annule, et il faut choisir explicitement le bouton d’exécution pour lancer l’action. Seul le bouton de suppression utilise la couleur de danger. En utilisateur non-root, l’affichage et les lectures restent disponibles, mais `u`, `d`, `l` et `a` sont refusés avant confirmation car ils exigent root.

Dans l’écran des journaux, `/` place le curseur dans la recherche ; `Entrée` valide le terme et positionne le journal sur le premier résultat, puis `n` et `N` parcourent les résultats dans les deux sens, avec le compteur affiché dans le titre. La touche `f` active ou désactive le suivi automatique, qui relit le fichier toutes les deux secondes et se place à la fin ; l’état du suivi reste visible à côté du champ de recherche.

La touche `C` (Maj+C) copie le texte de l’écran courant dans le presse-papiers du terminal. Dans les journaux et l’aide, elle copie d’abord la sélection faite dans la zone de texte ; sans sélection, elle copie tout le contenu affiché. Sur l’écran principal, elle copie le résumé, le tableau des modèles, le détail du modèle sélectionné et la barre d’état ; dans un écran de sortie, elle copie le titre, toute la sortie reçue et le statut final. Les écrans de confirmation et le menu d’actions peuvent aussi être copiés sans déclencher l’action. Dans un champ de saisie, Maj+C reste la saisie du caractère « C ». Cette copie utilise le mécanisme presse-papiers du terminal (OSC 52 via Textual) : le terminal doit l’accepter pour que le texte arrive dans le presse-papiers local.

La touche `t` fait défiler trois thèmes Textual choisis pour garder une interface lisible : `textual-dark` (défaut), `nord` et `textual-light`. Le dernier thème utilisé est écrit dans `~/.config/ola-tui/theme` — ou dans le fichier indiqué par `OLA_TUI_THEME_FILE` — et restauré au lancement suivant. Un fichier absent, illisible ou contenant un thème inconnu retombe proprement sur `textual-dark`.

### Limites de la TUI

- Elle nécessite un vrai terminal interactif ; dans un pipe ou un script, `ola tui` refuse de démarrer et renvoie vers les commandes texte.
- Elle ne remplace ni le menu `ola`, ni les commandes scriptables.
- Les actions passent par le CLI : un bench lancé depuis la TUI a donc les mêmes effets RAM que `ola bench` en ligne de commande.
- Le rendu exact dépend du terminal (taille, couleurs, police). Un terminal d’au moins environ 100 colonnes est recommandé pour tout voir ; `80×24` reste propre en mode compact, et les très petits terminaux conservent le tableau en masquant les panneaux.
- La copie Maj+C envoie le texte au presse-papiers du terminal (OSC 52) ; si le terminal ou le terminal web utilisé refuse ce mécanisme, la TUI affiche la copie comme envoyée mais le presse-papiers local peut rester inchangé.

## Utiliser l’API Ollama

L’URL publique enregistrée est affichée par :

```bash
ola status
```

Dans les exemples ci-dessous, remplace `https://ton-hostname.example` par ton URL publique réelle et `qwen3:1.7b` par ton modèle si tu en utilises un autre.

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
    "model": "qwen3:1.7b",
    "messages": [
      {"role": "user", "content": "Explique-moi simplement ce qu'est un tunnel Cloudflare."}
    ],
    "stream": false
  }'
```

Pour une réponse plus rapide sur les questions simples, ajoute `"think": false`, `"stream": true` et une limite `options.num_predict` (voir [Vitesse : mesurer et optimiser (Pack Speed)](#vitesse--mesurer-et-optimiser-pack-speed), et mesure avec `ola bench`). Pour la fluidité ressentie — premier token visible et flux régulier, en local comme via le tunnel — voir [Fluidité](#fluidité--premier-token-et-streaming) et `ola bench --stream` ; le preset complet à copier est donné par `ola fluid preset [modèle]`.

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
Model   : qwen3:1.7b
```

La clé `ollama` est une valeur de remplissage pour les clients qui exigent une clé ; elle n’ajoute pas d’authentification réelle, puisque le tunnel reste public.

Exemple :

```bash
curl -fsS https://ton-hostname.example/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ollama' \
  -d '{
    "model": "qwen3:1.7b",
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

Sur un sandbox déjà configuré avec une version qui connaît la commande, la mise à jour du gestionnaire se fait simplement avec :

```bash
sudo ola update
```

Puis vérifie :

```bash
ola doctor
ola test
ola watchdog
ola tui status
```

### Ce que fait `ola update`

Dans l’esprit du `manage.sh update` de nebula-p, mais adapté à l’installation `ola` qui n’est pas un dépôt Git :

1. un verrou empêche deux mises à jour simultanées ; un verrou dont le processus propriétaire a disparu est nettoyé ;
2. la commande télécharge la dernière version publiée de `ollama-cloudflare-setup.sh` et son fichier compagnon `ollama-cloudflare-setup.sh.sha256` ;
3. elle refuse l’installation si le SHA-256 ne correspond pas, si le fichier n’est pas un script `ola` reconnaissable ou si sa syntaxe Bash est invalide ;
4. si le SHA-256 installé est déjà celui de la version publiée, elle affiche `ola est déjà à jour` et ne redémarre pas les services ;
5. sinon, elle passe la main à la version téléchargée — comme nebula-p redémarre avec le `manage.sh` à jour — qui sauvegarde l’ancienne version dans `/usr/local/lib/ollama-cloudflare/backup/`, installe la nouvelle copie stable de façon atomique et met à jour les fichiers de la TUI ;
6. si les dépendances épinglées de la TUI ont changé et que son environnement Python existe déjà, elle essaie de le réparer ; un échec de cette étape optionnelle ne bloque pas la mise à jour du moteur ;
7. elle redémarre le watchdog, Ollama et cloudflared, puis attend que l’API Ollama réponde ;
8. si le redémarrage ou le contrôle de l’API échoue, elle restaure la version précédente depuis la sauvegarde et tente de redémarrer les services avec elle.

`ola update` met à jour le gestionnaire `ola` et les fichiers de la TUI. Il ne remplace ni les binaires Ollama/cloudflared, ni les modèles, ni l’URL/modèle enregistrés, ni les fichiers de configuration Supervisor existants. Un bref redémarrage des services est donc normal, mais les données et réglages persistants (Pack Speed, keep-alive, modèle par défaut) restent en place.

Les URL de téléchargement peuvent être remplacées pour un miroir ou un fork avec `OLA_UPDATE_URL` et `OLA_UPDATE_SHA256_URL` ; par défaut, elles pointent vers la branche publiée du dépôt `JCVERSA/Ssh.jc`.

### Première installation de la commande `update`

Si la version actuellement installée répond `Unknown argument: update`, elle est trop ancienne pour se mettre à jour elle-même. Télécharge une fois la nouvelle version, vérifie-la manuellement, puis lance son `update` :

```bash
cd /tmp
curl -fsSLO https://raw.githubusercontent.com/JCVERSA/Ssh.jc/arena/e89a71aa-ssh-jc/ollama-cloudflare-setup.sh
curl -fsSLO https://raw.githubusercontent.com/JCVERSA/Ssh.jc/arena/e89a71aa-ssh-jc/ollama-cloudflare-setup.sh.sha256
sha256sum -c ollama-cloudflare-setup.sh.sha256
chmod +x ollama-cloudflare-setup.sh
sudo ./ollama-cloudflare-setup.sh update
```

Ensuite, les mises à jour suivantes se feront directement avec `sudo ola update`.

Pour la toute première installation de l’interface TUI sur un ancien sandbox, crée ensuite son environnement Python isolé, puis lance-la :

```bash
sudo ola tui install
ola tui status
ola tui
```

Si une version future modifie les paramètres de génération des configurations — par exemple `OLLAMA_CONTEXT_LENGTH`, `CF_TUNNEL_PROTOCOL`, les paramètres Supervisor d’Ollama ou la configuration du tunnel — relance plutôt un setup pour régénérer proprement les fichiers concernés :

```bash
sudo ola setup
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

### `ola tui` ne démarre pas ou signale Textual absent

Vérifie l’état, puis répare l’environnement isolé :

```bash
ola tui status
sudo ola tui install
ola tui status
```

Causes fréquentes :

- lancement dans un pipe, un script ou un terminal non interactif : la TUI refuse volontairement et les commandes texte restent la bonne interface ;
- première mise à jour effectuée seulement avec `start` : le fichier Python a été extrait, mais le venv doit être créé une fois par `ola tui install` (ou par un setup complet) ;
- Python 3.11+, `python3-venv` ou l’accès réseau à PyPI manquant pendant l’installation ;
- paquets Python épinglés non installés ou venv incomplet : `ola tui install` recrée proprement un venv sans pip et réinstalle les versions de `tui-requirements.txt`.

Si la réparation échoue, le moteur n’est pas en panne : `ola status`, `ola doctor`, `ola models` et le menu texte continuent de fonctionner.

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
ola use qwen3:0.6b
```

Mesure la vitesse réelle et essaie le Pack Speed sûr :

```bash
ola bench
ola speed apply
ola bench
```

Vérifie aussi que tes requêtes simples utilisent `"think": false` et `"stream": true` (voir [Pack Speed](#vitesse--mesurer-et-optimiser-pack-speed)).

Évite d’augmenter `OLLAMA_CONTEXT_LENGTH` sur un sandbox de 2 Go sans tester progressivement.

### Réponses qui démarrent lentement ou arrivent par paquets

Distingue d’abord les deux symptômes avec la mesure (voir [Fluidité](#fluidité--premier-token-et-streaming)) :

```bash
ola bench --stream
ola fluid
```

- **Premier token lent, surtout à la première question après une pause** : le modèle n’était plus en RAM (chargement inclus dans le TTFT et dans le temps de chargement affiché). Garde-le chaud pendant la session : `ola fluid warm [modèle]`, ou rallonge le défaut serveur avec `ola fluid keepalive 30m` si la RAM le permet, ou envoie `"keep_alive": "30m"` dans tes requêtes.
- **Premier token lent à chaque requête, même à chaud** : prompt long à évaluer ou preset qui change à chaque appel. Garde un début de prompt stable (le compteur « prompt non caché » doit baisser quand le cache du prompt est réutilisé), réutilise le preset de `ola fluid preset [modèle]` sans changer `num_ctx`/`num_thread` entre deux requêtes, et borne `num_predict`.
- **TTFT local bon mais TTFT public très supérieur, ou morceaux qui arrivent par paquets via l’URL publique** : le chemin public (tunnel/client) bufferise ou retarde le flux ; ce n’est pas un réglage Ollama. Compare les deux lignes du bench streaming, teste depuis un autre client/réseau, et vérifie `ola doctor`. Cloudflare documente un buffering par défaut du trafic proxifié sauf si l’origine répond en `text/event-stream`, alors qu’Ollama streame en NDJSON : selon le client, l’affichage progressif peut donc ne pas être restitué tel quel via le tunnel même si le serveur streame correctement en local.
- **Réponse qui semble vide avant d’arriver d’un bloc** : sur un modèle à réflexion sans `think:false`, le budget de tokens peut être consommé par le thinking invisible ; la première partie visible arrive tard. Pour les questions simples, utilise `think:false` quand le modèle l’accepte.

### Un modèle refuse de se décharger de la RAM

Symptôme possible pendant un bench global ou un `ola speed apply` :

```text
Could not unload the currently loaded model: <modèle>. It may be busy; try again in a moment.
```

ou, avec le comportement actuel des séquences de bench/apply, un avertissement indiquant que le modèle reste chargé après plusieurs tentatives puis que la séquence continue.

Causes probables : le runner finit encore une requête (parfois une requête d’une application cliente connectée au tunnel), ou il met quelques secondes à se libérer après un test. Le déchargement renvoie maintenant la demande officielle `keep_alive: 0` plusieurs fois pendant environ 30 secondes.

Conduite à tenir :

1. vérifie ce qui est chargé : `ola ps` ;
2. arrête ou attends la fin des requêtes clientes en cours sur ce modèle ;
3. réessaie : `ola unload <modèle>`, puis `ola ps` ;
4. pour `ola bench` et `ola speed apply`, tu peux relancer la commande : la séquence continue modèle par modèle même si l’un d’eux tarde à se libérer ;
5. pour `ola use` et `ola delete`, le blocage est volontaire : l’ancien modèle doit être confirmé déchargé avant de continuer. Attends la fin de la requête en cours, puis réessaie ;
6. si le modèle reste chargé sans aucune requête en cours, consulte `ola logs` et `ola doctor`.

Si `ola speed apply` s’est arrêté sur ce message **pendant les mesures « avant »**, aucun réglage serveur n’a encore été appliqué : mets `ola` à jour, puis relance simplement `ola speed apply`.

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

### Origine des binaires et des paquets

Pendant le setup :

- Ollama est installé depuis l’archive officielle GitHub après vérification SHA-256 ;
- le script essaie plusieurs formats d’archive publiés (`tar.zst`, puis formats compressés publiés) et refuse une archive sans checksum correspondant ;
- cloudflared est installé d’abord via le dépôt apt officiel Cloudflare ;
- si ce dépôt échoue, le script retombe sur le paquet GitHub dont le digest SHA-256 est vérifié dans les métadonnées de release ;
- les dépendances Python de la TUI sont épinglées par version **et** par SHA-256, puis installées avec `pip --require-hashes` ;
- dans `Install.sh`, Node.js est installé depuis le dépôt apt signé de NodeSource : le script distant `setup_*.x` n’est ni téléchargé ni exécuté.

Un SHA-256 téléchargé depuis la même origine que l’artefact protège contre une corruption ou une substitution du fichier seul, mais il ne remplace pas une signature indépendante si le compte ou le dépôt de publication lui-même est compromis. C’est une limite résiduelle assumée pour les binaires et pour `ola update`.

### Durcissements appliqués au gestionnaire

- `ola update` refuse les URL non-HTTPS et borne la taille des téléchargements (10 Mio pour l’artefact, 4 Kio pour le fichier SHA-256) avant vérification.
- L’URL publique enregistrée est créée directement avec des permissions `600` : elle ne passe plus par une création temporaire dépendante de l’`umask` du shell.
- La configuration Supervisor générée refuse un contexte non numérique et les chemins de service contenant guillemets, antislashs, virgules ou retours à la ligne, afin qu’une variable d’environnement ne puisse pas injecter une autre directive dans la configuration.
- En mode Colab, seul un profil explicitement demandé (`OLA_COLAB=1`) ou le marqueur créé par un setup Colab précédent active les services en root ; les variables ambiantes `COLAB_*` ne suffisent plus. Le chemin de bibliothèques transmis à Ollama est limité aux emplacements NVIDIA fixes de Colab, sans recopier un `LD_LIBRARY_PATH` hérité.
- L’état restauré depuis Google Drive est validé avant copie dans `/etc` : fichiers réguliers uniquement (pas de liens symboliques), 4 Kio maximum, nom de modèle valide, mode Pack Speed connu et keep-alive valide.
- La file d’attente Ollama est limitée à 10 requêtes (`OLLAMA_MAX_QUEUE="10"`) en plus des limites existantes : 1 modèle chargé, 1 requête parallèle et contexte par défaut de 1024.

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

### Le même `ola` fonctionne-t-il sur VPS, sandbox et Google Colab ?

Oui. Sur VPS/sandbox Debian/Ubuntu, utilise le parcours classique : profil standard, utilisateurs dédiés et modèles locaux. Dans Google Colab, utilise le notebook `colab/Ola-Colab.ipynb` : il active le profil Colab, monte Google Drive, fait utiliser le GPU si présent et recrée une nouvelle URL Quick Tunnel à chaque runtime. Le profil Colab ne s'active pas par défaut sur un VPS/sandbox.

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

### Comment rendre les modèles plus rapides sans ajouter de RAM ?

L’optimisation est globale : elle concerne le serveur Ollama et tous les modèles présents, pas seulement le modèle par défaut.

1. Mesure : `ola bench` (tous les modèles présents, un par un ; compare pour chacun thinking par défaut et `think:false`). Pour un seul modèle : `ola bench <modèle>`.
2. Essaie `ola speed apply` (Flash Attention + cache KV `q8_0` pour tout le serveur, mesuré et vérifié modèle présent par modèle présent, réversible avec `ola speed reset`).
3. Côté application : `"think": false` pour les questions simples si le modèle le supporte, `"stream": true`, et `options.num_predict` raisonnable — le champ `model` reste à indiquer à chaque requête.
4. Garde un seul modèle en RAM (`ola ps`, `ola unload`).
5. Si un modèle reste trop lent, c’est souvent sa taille qui domine : un modèle plus petit répondra plus vite, indépendamment du Pack Speed.

### Comment rendre les réponses plus fluides (premier token rapide, texte qui défile) ?

La fluidité se mesure, elle ne se devine pas :

1. Mesure : `ola bench --stream` — temps avant le 1er token visible et régularité du flux, en local et via l’URL publique, pour chaque modèle présent ; `ola fluid` donne l’état (modèle chargé, expiration, keep-alive, RAM/swap).
2. Pendant une session, garde un seul modèle chaud : `ola fluid warm [modèle]` ; après la session, `ola unload` libère la RAM.
3. Envoie toujours le même preset stable à ce modèle (`ola fluid preset [modèle]`) : `stream:true`, `think:false` si le modèle l’accepte, même `num_ctx` à chaque requête, début de prompt stable pour profiter du cache du prompt.
4. Si le démarrage reste lent après chaque pause, rallonge le keep-alive du serveur (`ola fluid keepalive 30m`, retour avec `ola fluid keepalive reset`) en surveillant la RAM : le modèle reste chargé entre les requêtes, mais il occupe sa mémoire.
5. Si le local est fluide mais pas le public, le problème est le chemin tunnel/client, pas le serveur : compare les deux TTFT du bench streaming avant de changer un réglage.

Détail complet : [Fluidité : premier token et streaming](#fluidité--premier-token-et-streaming).

### La TUI remplace-t-elle les commandes `ola` ?

Non. `ola tui` est un habitacle plein écran au-dessus du même moteur. Elle lit l’API locale et appelle les commandes `ola` existantes pour les actions, donc les protections de `ola use`, `ola delete`, des benchs et des packs restent centralisées dans le moteur Bash. Le menu texte, `ola models` et toutes les commandes scriptables restent disponibles, y compris si Textual n’est pas installée.

### `ola speed apply` peut-il casser Ollama ?

La commande est conçue pour ne pas te laisser avec un réglage cassé : sauvegarde de l’ancienne configuration, redémarrage d’Ollama seul, vérification de l’API puis retest de chaque modèle présent, et restauration automatique de l’ancienne configuration si Ollama ne revient pas ou si un modèle qui fonctionnait ne répond plus. Et `ola speed reset` permet de revenir au mode `balanced` à tout moment.

---

# Fichiers et développement du projet

Le gestionnaire Ollama est maintenant développé comme un petit projet modulaire, tout en conservant un **artefact unique** pour l’installation sur le sandbox.

| Chemin | Rôle |
|---|---|
| `Install.sh` | Installeur interactif SSH + Cloudflare Tunnel / fxTunnel et pack d’outils VPS essentiels. N’a pas été restructuré dans cette étape. |
| `src/00-core.sh` | Constantes, utilitaires, Supervisor, binaires et commande `ola`. |
| `src/10-models.sh` | Modèles présents/chargés, déchargement, gestion interactive, suppression et changement de modèle. |
| `src/20-server-config.sh` | Configuration Supervisor Ollama, Pack Speed et keep-alive persistants. |
| `src/30-install-tunnels.sh` | Installation Ollama/cloudflared, tunnels Quick/Named et statut. |
| `src/40-runtime-watchdog.sh` | Modèle enregistré, watchdog et attentes de disponibilité. |
| `src/50-bench.sh` | Bench classique de génération, modèles présents et synthèse globale. |
| `src/55-fluid.sh` | Bench streaming/TTFT, état fluidité, préchauffage, preset et keep-alive serveur. |
| `src/58-speed.sh` | État, application, vérification et retour arrière du Pack Speed. |
| `src/60-diagnostics-setup.sh` | Doctor, test, récupération et setup complet. |
| `src/65-update.sh` | Auto-mise à jour du gestionnaire : téléchargement, SHA-256, verrou, sauvegarde, installation, redémarrage et retour arrière. |
| `src/67-colab.sh` | Profil Google Colab : état Google Drive, restauration/sauvegarde des réglages et statut CPU/GPU. |
| `colab/Ola-Colab.ipynb` | Notebook Colab de bout en bout : Drive, téléchargement vérifié, setup Quick, contrôles et test public. |
| `src/70-tui.sh` | Intégration Bash de la TUI : extraction, environnement Python, statut, réparation et lancement. |
| `src/90-main.sh` | Dispatch des commandes et menu texte historique. |
| `tui/ola_tui.py` | Application Textual `ola tui`. |
| `tui/requirements.txt` | Versions Python/Textual épinglées, embarquées dans l’artefact au build. |
| `build.sh` | Assemble `src/*.sh`, embarque `tui/ola_tui.py` et `tui/requirements.txt` dans `src/70-tui.sh`, vérifie la syntaxe et régénère l’artefact unique. |
| `ollama-cloudflare-setup.sh` | **Artefact généré par `build.sh`** : fichier unique téléchargé/installé sur le sandbox ; devient la commande `ola`. |
| `ollama-cloudflare-setup.sh.sha256` | SHA-256 publié de l’artefact, régénéré par `build.sh` et vérifié par `ola update`. |
| `tests/run-tests.sh` | Suite isolée Bash + Textual Pilot ; utilise uniquement des stubs et des namespaces temporaires. |
| `tests/run-tui-tests.py` | Tests headless de navigation et d’actions TUI simulées. |
| `tests/stub/` et `tests/fixtures/` | Faux `curl`, Ollama, Supervisor, Python/pip et faux fichiers système utilisés par les tests. |
| `README.md` | Documentation d’installation, d’utilisation et de développement. |

### Construire

Après toute modification dans `src/` ou `tui/`, régénère l’artefact distribué :

```bash
./build.sh
bash -n ollama-cloudflare-setup.sh
git diff --check
```

Ne modifie pas directement `ollama-cloudflare-setup.sh` pour un changement durable : modifie le module source correspondant, puis relance `./build.sh`. Le build régénère aussi `ollama-cloudflare-setup.sh.sha256`. Les commits doivent contenir à la fois les sources, l’artefact régénéré et son SHA-256, afin que le téléchargement direct et `ola update` restent toujours cohérents.

### Tester

La suite complète utilise des commandes factices et un namespace de montage : elle ne contacte ni un vrai Ollama, ni Cloudflare, ni PyPI pour les scénarios Bash.

```bash
tests/run-tests.sh
```

Options de validation renforcée :

```bash
SHELLCHECK=/path/to/shellcheck tests/run-tests.sh
python3 -m venv /tmp/ola-tui-dev
/tmp/ola-tui-dev/bin/pip install textual==8.2.8
OLA_TUI_TEST_PYTHON=/tmp/ola-tui-dev/bin/python tests/run-tests.sh
```

Sans Python/Textual disponible, les tests Bash s’exécutent et les tests Pilot sont explicitement signalés `SKIP`, pas comptés comme réussis. Avec `KEEP_TEST_WORK=1`, le dossier temporaire des tests est conservé pour inspection.

Pour la partie Ollama, les commandes à retenir sont :

```bash
ola status
ola doctor
ola test
ola bench
ola speed
ola fluid
ola tui
ola models
```
tils VPS essentiels. |
| `ollama-cloudflare-setup.sh` | Installeur et gestionnaire Ollama + Cloudflare Tunnel ; devient la commande `ola` après installation. |
| `README.md` | Documentation d’installation, de configuration et d’utilisation. |

Pour la partie Ollama, les commandes à retenir sont :

```bash
ola status
ola doctor
ola test
ola bench
ola speed
ola models
```
h
ola status
ola doctor
ola test
ola bench
ola speed
ola models
```
