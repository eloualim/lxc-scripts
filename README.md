# Odoo 18, 19 et 20 — LXC de développement sur Proxmox VE

Un conteneur **non privilégié Ubuntu 24.04** par version, avec Odoo **Community** depuis sa branche officielle, Python isolé, PostgreSQL et un service systemd. Les branches `18.0`, `19.0` et `20.0` sont vérifiées avant création ; aucun remplacement par `master`.

## Installation

Dans le shell **root du nœud Proxmox**, avec Internet :

```bash
git clone https://github.com/eloualim/lxc-scripts.git
cd lxc-scripts
bash create-odoo.sh 18
# Ou, pour des conteneurs distincts :
bash create-odoo.sh 19
bash create-odoo.sh 20
```

Par conteneur : 2 CPU, 4 Go RAM, disque 24 Go sur `local-lvm`, bridge `vmbr0`, DHCP, template sur `local`, identifiant libre choisi automatiquement. Le nœud doit disposer de Git (`apt-get update && apt-get install -y git` si nécessaire).

Pour SSH / VS Code Remote SSH, fournir **la clé publique de ton poste** :

```bash
SSH_PUBLIC_KEY=/root/mon-poste.pub bash create-odoo.sh 19
```

Sans clé : `pct enter ID_DU_CT`, puis `su - dev`. Aucun mot de passe SSH prédéfini. Connexion root SSH et authentification SSH par mot de passe désactivées.

### Personnalisation

```bash
CTID=220 STORAGE=local-lvm TEMPLATE_STORAGE=local BRIDGE=vmbr0 \
IP=192.168.1.220/24 GATEWAY=192.168.1.1 \
CORES=4 MEMORY=8192 DISK=40 SSH_PUBLIC_KEY=/root/mon-poste.pub \
bash create-odoo.sh 20
```

Adapter le réseau et les stockages. Le stockage disque doit accepter `rootdir`, celui des templates `vztmpl`. `TEMPLATE` permet de choisir un template officiel Ubuntu 24.04 précis. Aucun conteneur existant n'est supprimé, même après échec.

## Première utilisation

1. Ouvrir `http://IP_DU_CT:8069` sur le réseau local.
2. Lire le mot de passe maître : `pct exec ID_DU_CT -- cat /root/odoo-credentials.txt` depuis Proxmox.
3. Créer une base et choisir les identifiants de l'administrateur Odoo, distincts du mot de passe maître.
4. Se connecter avec `ssh dev@IP_DU_CT` ; ouvrir `/opt/odoo/custom-addons` avec son éditeur.

L'installation ne crée pas de base ni de compte applicatif avec des identifiants prédéfinis.

## Développer des modules

Dans le conteneur, connecté en `dev` :

```bash
odoo-scaffold mon_module
cd /opt/odoo/custom-addons/mon_module
# Modifier les fichiers, puis si nécessaire :
sudo systemctl restart odoo
```

Dans Odoo : activer le mode développeur, actualiser la liste des applications et rechercher le module (retirer le filtre « Applications » si nécessaire). Le rechargement Python/XML/QWeb est activé ; modifier modèles, manifestes ou données peut nécessiter une mise à niveau du module.

Pour mettre un module à niveau, depuis **root dans le conteneur**, remplacer les noms :

```bash
systemctl stop odoo
runuser -u odoo -- /opt/odoo/venv/bin/python /opt/odoo/src/odoo-bin \
  -c /etc/odoo.conf -d ma_base -u mon_module --stop-after-init --no-http
systemctl start odoo
```

En cas d'erreur, examiner le résultat et redémarrer le service. Pour installer les dépendances d'un module depuis root :

```bash
runuser -u odoo -- /opt/odoo/venv/bin/pip install -r /opt/odoo/custom-addons/mon_module/requirements.txt
systemctl restart odoo
```

| Chemin | Usage |
| --- | --- |
| `/opt/odoo/custom-addons` | Modules ; propriétaire `dev`, groupe `odoo`, mode `2770`, ACL héritées pour `dev` et `odoo` |
| `/opt/odoo/src` | Sources officielles |
| `/opt/odoo/venv` | Python et dépendances |
| `/etc/odoo.conf` | Configuration, root et groupe `odoo` uniquement |
| `/var/lib/odoo` | Données et filestore |
| `/root/odoo-credentials.txt` | Mot de passe maître, root uniquement |

Les fichiers créés normalement dans `custom-addons` héritent des droits partagés sans `chmod 777`. Un outil imposant ensuite `chmod 600` peut retirer ces droits : éviter de préserver des permissions restrictives lors des copies. `dev` peut démarrer, arrêter et redémarrer Odoo. C'est un compte de confiance : les modules s'exécutent avec les droits Odoo.

## Diagnostic et reprise

```bash
# Depuis Proxmox :
pct enter ID_DU_CT
# Puis dans le conteneur :
systemctl status odoo
journalctl -u odoo -n 100 --no-pager
getfacl /opt/odoo/custom-addons
bash /root/install-odoo.sh 19  # reprendre avec la même version
```

Après échec, le conteneur est conservé. Corriger la cause avant reprise. Si l'échec précède la copie de l'installateur, depuis le dépôt sur le nœud :

```bash
pct push ID_DU_CT install-odoo.sh /root/install-odoo.sh --perms 700
pct exec ID_DU_CT -- bash /root/install-odoo.sh 19
```

La reprise conserve configuration et modules et refuse un changement de version. Un clone interrompu peut nécessiter de déplacer `/opt/odoo/src` incomplet avant reprise. L'installateur est réservé à ces conteneurs dédiés, pas à un serveur existant.

## Périmètre et validation

- Développement sur réseau de confiance avec gestionnaire de bases accessible ; ne pas exposer directement le port 8069 sur Internet.
- Pas d'Enterprise, migration de version, sauvegardes automatiques ou reverse proxy TLS.
- `wkhtmltopdf` avec Qt patché n'est pas installé : les rapports PDF nécessitent sa configuration séparée.
- CI : syntaxe Bash, ShellCheck et simulation du créateur Proxmox. En fin d'installation, le script vérifie la réponse HTTP d'Odoo. **L'installation réelle sur Proxmox reste à valider.**

Références : [installation Odoo](https://www.odoo.com/documentation/19.0/administration/on_premise/source.html), [sources officielles](https://github.com/odoo/odoo), [Proxmox](https://pve.proxmox.com/pve-docs/).
