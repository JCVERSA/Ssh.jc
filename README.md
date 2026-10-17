# Ssh.jc — Install.sh

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

## Notes de sécurité

- Le script rend SSH joignable depuis Internet une fois le tunnel lancé : préfère un utilisateur admin dédié avec clé SSH, puis désactive l’authentification par mot de passe quand c’est proposé.
- Avant modification, `sshd_config` est sauvegardé et vérifié avec `sshd -t` / `sshd -T`.
- Les paquets/scripts distants sans checksum vérifiable ne sont pas installés automatiquement.
