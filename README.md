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
7. Quitter

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
