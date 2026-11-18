# Guide de lecture de l'interface

Ce guide explique ce que vous voyez à l'écran et comment le lire.

## 1. L'écran d'accueil

```
                              [● Données du 12/11 à 13:45 · 13 002 groupes · 2 115 éléments]  [⟳][⌂][⚙]

                              Intune Lens
                    Qui reçoit quoi dans Intune, groupe par groupe.

              ┌──────────────────────────────────────────────────────┐
              │ 🔍  Rechercher un groupe Entra                    /  │   ← barre de recherche
              └──────────────────────────────────────────────────────┘
                       [ Groupe Entra | Configuration ]                    ← que cherchez-vous ?
```

- **Bandeau orange « MODE DÉMO »** : vous êtes sur des données **inventées**. Aucun nom affiché n'existe dans votre tenant.
- **Pastille en haut à droite** : la date des données affichées et leur volume.
  - Point **vert** : données à jour.
  - Point **bleu** clignotant : synchronisation en cours (avec le pourcentage).
  - Point **orange** : Microsoft ralentit les requêtes (429) ; la reprise est automatique.
  - Point **rouge** : la dernière synchronisation a échoué.
  - Cliquez sur la pastille pour voir le détail et lancer une synchronisation.
- **Sélecteur « Groupe Entra | Configuration »** : choisit le sens de la question.
  - **Groupe Entra** : « qu'est-ce qui est assigné à ce groupe ? »
  - **Configuration** : « à quels groupes cet élément est-il assigné ? » Cela couvre les configurations, la conformité, les applications, les scripts, les remédiations, etc.

**Essai rapide** : tapez `reference` puis `Entrée`. Le groupe de démo « GRP-Référence-Démo-26 » s'ouvre. Il joue le rôle de votre `<GROUPE_REFERENCE>` : 26 éléments.

## 2. Écran « Groupe → éléments »

```
┌─ GROUPE ENTRA ────────────────────────────────────────────────────────────────┐
│ GRP-Référence-Démo-26                                                     26  │
│ 1b2c…-…  [Copier]                                           éléments assignés │
└───────────────────────────────────────────────────────────────────────────────┘
 [Applications 6] [Catalogue de paramètres 5] [Configuration (modèles) 3] …   ← clic = filtre
 [Filtrer les résultats]  Statut [Tous ▾]  Via [Tous ▾]       [Copier le tableau] [Exporter CSV]

 NOM                         TYPE                   STATUT     VIA            INTENT       FILTRE
 ▾ Applications · 6 éléments
   Agent ERP - Qualité - 104  Application Win32    ✓ Inclus   Groupe direct  Obligatoire  Filtre-… (inclure)
   …                                               ⊘ Exclu    Groupe direct  Obligatoire  —
 ▾ Catalogue de paramètres · 5 éléments
   …
 ▸ Assignations globales (indicatif) · 293 règles · 1 exclusion de ce groupe
```

Comment lire une ligne :

| Colonne | Signification |
|---|---|
| **Nom** | Nom de l'élément Intune (et sa plateforme en dessous). |
| **Type** | Type précis : application Win32, profil de restrictions, script, etc. |
| **Statut** | **✓ Inclus** : le groupe reçoit l'élément. **⊘ Exclu** : le groupe est explicitement exclu de cet élément. |
| **Via** | « Groupe direct » : l'assignation vise ce groupe nommément. |
| **Intent** | Applications seulement : Obligatoire / Disponible / Désinstaller. |
| **Filtre** | Filtre d'assignation éventuel, et s'il **inclut** ou **exclut** les appareils qui y correspondent. |

La section **Assignations globales (indicatif)** est repliée par défaut. Elle liste les éléments assignés à « Tous les utilisateurs » ou « Tous les appareils ».

- Ces éléments touchent **peut-être** votre groupe, selon que ses membres sont des utilisateurs ou des appareils. La v1 ne le calcule pas.
- Si votre groupe est **exclu** d'une de ces règles, la ligne l'indique (⊘ Exclu).

Un **clic sur une ligne** ouvre le panneau de droite :

- détail complet de l'élément : identifiants, dates, filtre ;
- bouton « Voir toutes les cibles de cet élément », qui bascule vers l'écran 3.

## 3. Écran « Élément → groupes »

- En-tête : nom de l'élément, famille, plateforme, date de dernière modification.
- Liste des cibles :
  - d'abord « Tous les utilisateurs » / « Tous les appareils » s'il y en a ;
  - puis les groupes inclus, puis les groupes exclus.
- Un clic sur un groupe, puis « Ouvrir ce groupe », revient à l'écran 2 pour ce groupe.
- « Groupe supprimé (…) » : l'assignation vise un groupe qui n'existe plus dans Entra.

## 3 bis. Écran « Comparer »

- Depuis un groupe ou un élément : bouton **« Comparer »**. La recherche du haut affiche « Comparer avec… » et ne propose que le **même type** (groupe ↔ groupe, élément ↔ élément). `Échap` annule.
- En-tête : **A** à gauche, **B** à droite, ⇄ pour inverser, « Fermer » pour revenir à A.
- Tableau : une ligne par élément (ou par groupe), colonne A, colonne B et colonne **Écart** :
  - **Seulement A / Seulement B** : présent d'un seul côté (l'autre affiche « Absent ») ;
  - **Différent** : inclus d'un côté, exclu de l'autre (ou paramètres différents) ;
  - **Identique** : même assignation des deux côtés.
- Par défaut tout est affiché, écarts en premier et soulignés d'une barre bleue ; la pastille « Écarts » ne garde que les différences.
- Comparaison de groupes : les assignations « Tous les utilisateurs / appareils » ne sont pas comptées (elles touchent les deux groupes), **sauf** quand un des groupes en est exclu.

## 3 ter. Fiches « Utilisateur » et « Machine »

- **Recherche** : choisissez le type avec le sélecteur (icônes personne, PC, groupe, clé) ou les touches `U`, `M`, `G`, `C`.
- **Fiche Utilisateur** : trois onglets.
  - **Configurations** : tout ce qui vise cet utilisateur ou l'un de ses PC. La colonne **Appareils** dit où : « Tous ses appareils » (ciblage par l'utilisateur), le nom d'un PC (ciblage par un groupe d'appareils), un PC barré d'un cercle (exclu sur ce PC). Un PC estompé est inactif (plus de 30 jours sans synchro). Le filtre « Appareil » isole un PC.
  - **Groupes** : tous ses groupes Entra, y compris par imbrication ; ceux qui servent dans Intune d'abord ; 20 par page.
  - **Appareils** : ses PC et téléphones gérés, dernière synchro, conformité.
- **Fiche Machine** : utilisateur principal (cliquer pour ouvrir sa fiche), groupes de la machine, éléments ciblés. La colonne **Ciblage** dit si l'élément arrive par l'utilisateur ou par l'appareil.
- **« Exclusion non garantie »** : l'élément est inclus par un groupe d'utilisateurs et exclu par un groupe d'appareils (ou l'inverse). Intune ne prend pas en charge ce mélange : l'exclusion peut ne pas s'appliquer. L'outil garde donc l'élément « Inclus ».
- **À garder en tête** : la fiche montre ce qui est **ciblé**, pas l'état réel du déploiement ; les filtres d'assignation ne sont pas évalués.

## 4. Raccourcis utiles

| Touche | Action |
|---|---|
| `/` | Aller à la recherche |
| `Échap` | Fermer le panneau ou le menu, puis revenir à l'accueil |
| `U` / `M` / `G` / `C` | Chercher un utilisateur / une machine / un groupe / une configuration |
| `Ctrl+V` | Coller un lien « Copier le lien » reçu d'un collègue : ouvre la fiche |
| `R` / `Maj+R` | Synchronisation incrémentale / complète |
| `T` | Basculer mode clair / sombre (aussi : ⚙ → « Mode sombre ») |
| Flèches, `Entrée` | Naviguer dans les suggestions et le tableau, ouvrir |

## 5. Pour comprendre la synchronisation en démo

1. Lancez `pwsh -File .\Start-IntuneAssignLens.ps1 -Mock`, puis arrêtez avec `Ctrl+C`.
2. Relancez avec `-Mock -MockDataset modified`. Ce jeu « modifié » simule quelques changements faits dans Intune entre-temps.
3. Les données s'affichent tout de suite (depuis le cache). Quelques secondes plus tard, un message indique « Données mises à jour : 5 nouveaux, 6 modifiés, 5 supprimés ».
4. Seuls ces éléments ont été relus. C'est la synchronisation incrémentale.
