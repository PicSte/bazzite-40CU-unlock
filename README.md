# bazzite-deck-bc250

Image **Bazzite Deck officielle** (`ghcr.io/ublue-os/bazzite-deck:stable`) avec une seule modification : le module `amdgpu` est recompilé avec le patch de déverrouillage **40 CU** de l'AMD BC-250 ([duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock)).

- Même noyau OGC que Bazzite, même Fedora, mêmes mises à jour : la CI suit `bazzite-deck:stable` chaque jour.
- Seul `amdgpu.ko` est reconstruit, à partir du tag OpenGamingCollective/linux qui correspond exactement au noyau de l'image (`7.2.9-ogc3.1.fc44` → `v7.2.9-ogc3`), contre le `kernel-devel` de l'image elle-même.
- Le patch ne fait rien tant que le paramètre `amdgpu.bc250_cc_write_mode` vaut 0 (défaut). Il ne s'active que sur l'ID PCI `0x13FE`.
- Si une nouvelle version de Bazzite casse le patch ou la compilation, la CI échoue et **aucune image n'est publiée** : la machine reste sur la dernière version qui fonctionne.

## Contenu

| Fichier | Rôle |
|---|---|
| `Containerfile` | Build en deux étapes : compilation d'amdgpu (Fedora), puis image finale |
| `build_files/build-amdgpu.sh` | Récupère les sources OGC exactes, applique les patchs, compile, vérifie le vermagic |
| `build_files/install-amdgpu.sh` | Remplace le module, `depmod`, régénère l'initramfs, configure la signature |
| `patches/bc250-40cu-amdgpu.patch` | Patch 40 CU (rebasé sur 7.2, lignes ajoutées identiques à l'original) |
| `.github/workflows/build.yml` | Build quotidien, push sur ghcr.io, signature cosign |

## 1. Mise en place du dépôt GitHub

1. Crée un dépôt **public** vide sur GitHub, par exemple `bazzite-deck-bc250`, puis pousse ce dossier (c'est déjà un dépôt git avec un premier commit sur `main`) :

   ```bash
   git remote add origin git@github.com:<utilisateur>/bazzite-deck-bc250.git
   git push -u origin main
   ```
2. Génère une paire de clés de signature (sur la BC-250, Homebrew est fourni par Bazzite) :

   ```bash
   brew install cosign
   cosign generate-key-pair      # laisser le mot de passe VIDE (deux fois Entrée)
   ```

3. Commite **`cosign.pub`** à la racine du dépôt. Ne commite jamais `cosign.key` (déjà dans `.gitignore`).
4. Dans *Settings → Secrets and variables → Actions*, crée le secret **`SIGNING_SECRET`** avec le contenu complet de `cosign.key`.
5. Dans *Actions*, lance **Build bazzite-deck-bc250 → Run workflow**. Compte 30 à 60 minutes.
6. Après le premier build réussi, rends le paquet public : *ton profil → Packages → bazzite-deck-bc250 → Package settings → Change visibility → Public*. Sinon `rpm-ostree` ne pourra pas le télécharger.

## 2. Installation sur la BC-250

Remplace `<utilisateur>` par ton nom GitHub **en minuscules**.

```bash
# 1er passage : l'image n'est pas encore connue du système, donc non vérifiée
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/<utilisateur>/bazzite-deck-bc250:latest
systemctl reboot

# 2e passage : bascule en vérification de signature (la clé est maintenant dans l'image)
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/<utilisateur>/bazzite-deck-bc250:latest
systemctl reboot
```

Vérifie que le module patché est bien chargé :

```bash
rpm-ostree status | head -5
modinfo -F parm amdgpu | grep bc250
```

Tes réglages locaux suivent le rebase : arguments noyau (`rpm-ostree kargs`), régénération locale de l'initramfs (override ACPI via dracut), paquets superposés.

## 3. Activation des 40 CU (une seule fois)

```bash
sudo rpm-ostree kargs --append-if-missing=amdgpu.bc250_cc_write_mode=3
systemctl reboot
```

Après redémarrage :

```bash
sudo dmesg | grep bc250-40cu
vulkaninfo 2>/dev/null | grep -i activeComputeUnitCount   # 40 attendu
```

C'est **permanent** : l'argument noyau reste d'une mise à jour à l'autre et le pilote applique le déverrouillage à chaque démarrage, sans script ni service.

À savoir :

- Si tu utilises `cyan-skillfish-governor-smu`, l'auteur de l'image d'origine recommande de le désactiver : `sudo systemctl disable --now cyan-skillfish-governor-smu.service`.
- Toutes les cartes ne tiennent pas les 40 CU. En cas d'artefacts ou de plantages GPU, certains CU sont peut-être défectueux : `amdgpu.disable_cu=<se>.<sh>.<cu>,…` permet de les masquer.
- Les 16 CU supplémentaires chauffent : surveille les températures et le refroidissement de la mémoire.

## 4. Mises à jour

Rien à faire : la CI reconstruit l'image quand `bazzite-deck:stable` change, et la machine se met à jour normalement (`ujust update`, mise à jour automatique ou `rpm-ostree upgrade`).

- Les nouvelles versions arrivent jusqu'à 24 h après Bazzite (horaire du cron).
- **N'utilise pas `bazzite-rollback-helper rebase stable`** : il te ramènerait sur l'image officielle, sans le patch.
- Si la CI échoue (patch qui ne s'applique plus, tag OGC introuvable…), GitHub t'envoie un e-mail et ta machine reste sur la dernière image valide.

## 5. Retour arrière

| Situation | Commande |
|---|---|
| Désactiver le 40 CU | `sudo rpm-ostree kargs --delete=amdgpu.bc250_cc_write_mode=3` |
| La machine ne démarre plus en 40 CU | Au menu GRUB, `e` sur l'entrée, ajouter `amdgpu.bc250_cc_write_mode=0` à la ligne `linux`, puis Ctrl-X |
| Revenir au déploiement précédent | `sudo rpm-ostree rollback` |
| Revenir à Bazzite officiel | `sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ublue-os/bazzite-deck:stable` |

## Dépannage

- **`rpm-ostree` refuse l'image signée** : `/etc/containers/policy.json` a peut-être été modifié localement, et OSTree garde alors ta version au lieu de celle de l'image. Compare avec `diff /usr/etc/containers/policy.json /etc/containers/policy.json`.
- **Build qui échoue sur le tag** : le format de version du noyau OGC a changé. Lance le workflow à la main et adapte la regex dans `build-amdgpu.sh`, ou fixe `OGC_TAG`.
- **Build qui échoue sur le patch** : le code de `gfx_v10_0_get_cu_info()` a bougé en amont ; il faut rebaser `patches/bc250-40cu-amdgpu.patch`.
