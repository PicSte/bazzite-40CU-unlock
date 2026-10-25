# bazzite-40CU-unlock

Image **Bazzite Deck officielle** (`ghcr.io/ublue-os/bazzite-deck:stable`) avec une seule modification : le module `amdgpu` est recompilé avec le patch de déverrouillage **40 CU** de l'AMD BC-250 ([duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock)).

Image publiée : **`ghcr.io/picste/bazzite-deck-bc250`**

- Même noyau OGC que Bazzite, même Fedora, mêmes mises à jour : GitHub Actions vérifie `bazzite-deck:stable` toutes les 6 heures et reconstruit l'image dès qu'elle change.
- Seul `amdgpu.ko` est reconstruit, à partir du tag OpenGamingCollective/linux qui correspond exactement au noyau de l'image (`7.2.9-ogc3.1.fc44` → `v7.2.9-ogc3`), contre le `kernel-devel` de l'image elle-même.
- Le patch ne fait rien tant que `amdgpu.bc250_cc_write_mode` vaut 0 (défaut), et ne s'active que sur l'ID PCI `0x13FE`.
- Si une nouvelle version de Bazzite casse le patch ou la compilation, **aucune image n'est publiée** : la BC-250 reste sur la dernière version qui fonctionne, et une issue s'ouvre dans ce dépôt.

## Installation sur la BC-250

En mode Bureau, ouvre **Konsole** et lance :

```bash
curl -fsSL https://raw.githubusercontent.com/PicSte/bazzite-40CU-unlock/HEAD/bc250-setup.sh -o /tmp/bc250-setup.sh
sudo bash /tmp/bc250-setup.sh
```

C'est tout. Le script :

1. vérifie que tu es sur Bazzite, que la BC-250 est détectée et que l'image est publiée ;
2. bascule le système sur `ghcr.io/picste/bazzite-deck-bc250:latest` (`rpm-ostree rebase`, seules les couches modifiées sont téléchargées) ;
3. ajoute l'argument noyau `amdgpu.bc250_cc_write_mode=3` (déverrouillage 40 CU) ;
4. s'installe dans `/usr/local/bin/bc250-setup` avec un petit service de finalisation ;
5. propose de redémarrer (Entrée = oui).

Au redémarrage, la BC-250 tourne en 40 CU. Deux minutes après, le service de finalisation vérifie le module et active tout seul la **vérification de signature** de l'image (`ostree-image-signed`), puis se désactive. Sans clé de signature (voir plus bas), il réessaie à chaque démarrage, sans rien bloquer.

Pour une installation sans aucune question : `sudo bash /tmp/bc250-setup.sh --yes`.

### Vérifier

```bash
sudo bc250-setup status
```

Affiche l'image démarrée, l'état de la signature, si le module patché est chargé, le nombre de CU actifs (40 attendu) et la température du GPU.

Pour aller plus loin : `RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep num_cu` (40 attendu).

### Autres commandes

| Commande | Effet |
|---|---|
| `sudo bc250-setup status` | État complet |
| `sudo bc250-setup disable-40cu` | Retire l'argument noyau (retour à 24 CU, image conservée) |
| `sudo bc250-setup enable-40cu` | Le remet |
| `sudo bc250-setup uninstall` | Revient à l'image Bazzite d'origine et supprime le script |
| `bc250-setup signing-key` | Crée la clé de signature pour GitHub (voir plus bas) |
| `bc250-setup --help` | Toutes les options (`--no-40cu`, `--no-reboot`, `--image`, `--tag`) |

Tes réglages locaux suivent la bascule : autres arguments noyau, paquets superposés, initramfs régénéré localement.

### À savoir

- Toutes les cartes ne tiennent pas les 40 CU. En cas d'artefacts ou de plantages GPU, certains CU sont peut-être défectueux : `sudo rpm-ostree kargs --append=amdgpu.disable_cu=<se>.<sh>.<cu>,…` permet de les masquer.
- Les 16 CU supplémentaires chauffent : à 2 GHz, ~181 W et 96 °C d'après l'auteur du patch. Il conseille de plafonner le GPU à 1500 MHz / 900 mV avec `cyan-skillfish-governor` (83 °C, toujours ~1,6× plus rapide qu'en 24 CU).
- Si tu utilises `cyan-skillfish-governor-smu`, l'auteur de l'image d'origine recommande de le désactiver : `sudo systemctl disable --now cyan-skillfish-governor-smu.service`.

## Mises à jour

Rien à faire : la CI reconstruit l'image quand `bazzite-deck:stable` change, et la BC-250 se met à jour comme d'habitude (mise à jour automatique de Bazzite, `ujust update` ou `rpm-ostree upgrade`).

- Les nouvelles versions arrivent au plus 6 h après Bazzite, plus ~1 h de build.
- **N'utilise pas `bazzite-rollback-helper rebase …`** : il te ramènerait sur l'image officielle, sans le patch.
- Dependabot propose chaque semaine une PR pour mettre à jour les actions GitHub ; la fusionner suffit.

## Côté GitHub

Le dépôt fonctionne seul : chaque push sur la branche par défaut et chaque passage planifié construit et publie l'image si nécessaire. Les autres branches construisent sans publier (pour tester un changement).

| Workflow | Rôle |
|---|---|
| `build.yml` | Toutes les 6 h : compare l'image de base et les sources, reconstruit, publie sur ghcr.io, signe. Ouvre une issue `build-failure` en cas d'échec et la ferme au build suivant réussi. Garde la planification active (GitHub la coupe après 60 jours sans activité). |
| `lint.yml` | Vérifie les scripts shell (ShellCheck) |
| `dependabot.yml` | Mises à jour des actions |

### Une fois, après le premier build

1. **Paquet public** : *Profil → Packages → bazzite-deck-bc250 → Package settings → Change visibility → Public*. Sans ça, la BC-250 ne peut pas télécharger l'image (le script te le dit avec le lien direct).
2. **Branche par défaut** : *Settings → General → Default branch*. Les builds planifiés tournent sur la branche par défaut : c'est elle qui publie.

### Signature (recommandé)

Sans signature, l'image est publiée quand même et la BC-250 l'utilise en mode « non vérifié ». Pour activer la vérification, il suffit d'ajouter un secret, une seule fois. Sur la BC-250 (cosign est fourni par Bazzite), **sans sudo** :

```bash
bc250-setup signing-key
```

La commande crée la clé dans `~/.config/bc250-signing/`, puis :

- si `gh` est installé et connecté (`brew install gh && gh auth login`), elle enregistre le secret `SIGNING_SECRET` et relance le build toute seule ;
- sinon, elle affiche la clé et le lien où la coller (*Settings → Secrets and variables → Actions → New repository secret*, nom `SIGNING_SECRET`), puis il reste à relancer le build (*Actions → Build bazzite-deck-bc250 → Run workflow*).

La clé publique est dérivée du secret par la CI et intégrée à l'image : rien d'autre à commiter. Au démarrage qui suit le build signé, la BC-250 passe toute seule en `ostree-image-signed`.

> **Ne change pas de clé ensuite** : la BC-250 vérifie chaque mise à jour avec la clé de l'image installée. Après un changement de clé, il faut relancer `sudo bc250-setup install` (qui repasse brièvement en mode non vérifié).

## Retour arrière

| Situation | Commande |
|---|---|
| Désactiver le 40 CU | `sudo bc250-setup disable-40cu` |
| La machine ne démarre plus en 40 CU | Au menu GRUB, `e` sur l'entrée, ajouter `amdgpu.bc250_cc_write_mode=0` à la ligne `linux`, puis Ctrl-X ; ensuite `sudo bc250-setup disable-40cu` |
| Revenir au déploiement précédent | `sudo rpm-ostree rollback` |
| Revenir à Bazzite officiel | `sudo bc250-setup uninstall` |

## Contenu

| Fichier | Rôle |
|---|---|
| `bc250-setup.sh` | Script d'installation et de gestion sur la BC-250 |
| `Containerfile` | Build en deux étapes : compilation d'amdgpu (Fedora), puis image finale |
| `build_files/build-amdgpu.sh` | Récupère les sources OGC exactes, applique les patchs, compile, vérifie le vermagic |
| `build_files/install-amdgpu.sh` | Remplace le module, `depmod`, régénère l'initramfs, configure la signature |
| `patches/bc250-40cu-amdgpu.patch` | Patch 40 CU (rebasé sur 7.2, lignes ajoutées identiques à l'original) |
| `keys/` | Reçoit `cosign.pub`, écrit par la CI à partir du secret |

## Dépannage

- **Le script dit que l'image est privée** : rends le paquet public (voir « Côté GitHub »).
- **Le script dit que l'image n'est pas publiée** : le premier build prend 30 à 60 minutes ; suis-le dans l'onglet *Actions*.
- **Finalisation bloquée** : `journalctl -u bc250-setup` montre ce que fait le service à chaque démarrage.
- **`rpm-ostree` refuse l'image signée** : `/etc/containers/policy.json` a peut-être été modifié localement (OSTree garde alors ta version). Le service y reporte normalement l'entrée de l'image ; compare avec `diff /usr/etc/containers/policy.json /etc/containers/policy.json`.
- **Issue « Le build automatique de l'image échoue »** : ouvre le lien du run.
  - *tag introuvable* : le format de version du noyau OGC a changé ; adapte la regex dans `build-amdgpu.sh`, ou fixe `OGC_TAG`.
  - *le patch ne s'applique plus* : `gfx_v10_0_get_cu_info()` a bougé en amont ; il faut rebaser `patches/bc250-40cu-amdgpu.patch`.
