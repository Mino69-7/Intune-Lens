# Checklist de test manuel (Edge) : jalon M2

À faire par l'utilisateur dans Microsoft Edge (spec 9.4). Claude Code ne lance pas de navigateur automatisé.
Cochez chaque ligne, notez les anomalies dans la colonne « Remarque » (capture d'écran bienvenue).

## Préparation

```powershell
cd <dossier>\IntuneAssignLens
pwsh -File .\Start-IntuneAssignLens.ps1 -Mock
```

Edge s'ouvre. Le bandeau **« MODE DÉMO : données fictives »** doit être visible.

> La librairie Liquid Glass n'étant pas encore déposée (jalon M0), l'interface fonctionne en **verre CSS**.
> Réglages (⚙) → « Rendu actuel » doit indiquer « Verre CSS ». C'est le comportement attendu à ce stade.

## A. Recherche et navigation

| # | Action | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| A1 | Appuyer sur `/` | Le champ de recherche prend le focus | ☐ | |
| A2 | Taper `reference demo` (sans accents) | « GRP-Référence-Démo-26 » apparaît dans les suggestions, avec « 26 éléments » | ☐ | |
| A3 | Flèches ↓ ↑ puis `Entrée` | La suggestion active est surlignée ; `Entrée` ouvre le groupe | ☐ | |
| A4 | Vérifier l'en-tête | Nom, identifiant + bouton « Copier », total **26** | ☐ | |
| A5 | Bandeau de synthèse : cliquer sur une famille | Le tableau se filtre ; recliquer annule | ☐ | |
| A6 | Colonnes | Nom, Type, Statut (icône + texte Inclus / Exclu), Via, Intent (apps), Filtre | ☐ | |
| A7 | Cliquer une section (ex. « Applications ») | Elle se replie / se déplie | ☐ | |
| A8 | Déplier « Assignations globales (indicatif) » | Note explicative ; une règle porte « Exclu » (exclusion de ce groupe sur Tous les appareils) | ☐ | |
| A9 | Filtres : texte, Statut = Exclus, Via = Assignations globales | Le tableau suit ; « Aucun résultat avec ces filtres » + bouton de réinitialisation si vide | ☐ | |
| A10 | Cliquer une ligne | Panneau latéral : détail, filtre résolu, bouton « Voir toutes les cibles de cet élément » | ☐ | |
| A11 | Dans le panneau, ouvrir « Voir toutes les cibles » | Écran Élément → groupes : cibles globales en tête, puis groupes | ☐ | |
| A12 | Cliquer une ligne de groupe puis « Ouvrir ce groupe » | Retour à l'écran Groupe pour ce groupe | ☐ | |
| A13 | Bouton Précédent d'Edge | Retour à l'écran précédent | ☐ | |
| A14 | `C` puis taper `sans assignation` et ouvrir | « Aucune assignation » (orphelin potentiel) | ☐ | |
| A15 | `G` puis `GRP-Sans-Assignation` | « Aucune assignation directe » ; règles globales toujours listées | ☐ | |
| A16 | Rechercher `<b>Groupe` et ouvrir | Le nom s'affiche comme du **texte** (balises visibles, rien d'interprété, aucune alerte) | ☐ | |
| A17 | Rechercher `GRP-Doublon` | Deux groupes de même nom, identifiants différents | ☐ | |
| A18 | Dans PowerShell : `(Get-Content .\mock\fixtures\expected.json \| ConvertFrom-Json).deletedGroupId`. Puis, dans la barre d'adresse d'Edge, ajouter `#/group/<cet id>` à la fin de l'URL et valider (seul le fragment change : la page ne se recharge pas) | En-tête « Groupe supprimé (…) », mention « Supprimé dans Entra » et note explicative ; 3 éléments ; aucun plantage | ☐ | |
| A19 | `Échap` successifs | Ferme le panneau / le menu, puis revient à l'accueil | ☐ | |
| A20 | Accueil | « Recherches récentes » listées ; « Effacer » les vide | ☐ | |

## B. Exports

| # | Action | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| B1 | Groupe de référence → « Exporter CSV » | Fichier `.csv` ; ouvert dans Excel : colonnes séparées, accents corrects (UTF-8 BOM, séparateur `;`) | ☐ | |
| B2 | « Copier le tableau » puis coller dans Excel | Colonnes correctement réparties | ☐ | |
| B3 | Export après filtre | Seules les lignes filtrées sont exportées | ☐ | |

## C. Thème et affichage

| # | Action | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| C1 | ⚙ → interrupteur « Mode sombre » (ou `T`) | Bascule clair ↔ sombre ; l'interrupteur passe au bleu à droite en sombre ; choix mémorisé après relance | ☐ | |
| C2 | Thème clair et sombre | Textes lisibles partout, y compris sur les zones colorées du fond | ☐ | |
| C3 | ⚙ → section « Tenant » | « Tenant synchronisé » avec une coche bleue quand les données sont à jour ; ID du tenant et date de la dernière synchro | ☐ | |
| C4 | Windows : Paramètres → Accessibilité → Thèmes de contraste | Couleurs système, aucun effet de verre, tout reste utilisable | ☐ | |
| C5 | Redimensionner la fenêtre (large → étroite) | La barre du haut passe sur deux lignes ; rien ne se chevauche | ☐ | |
| C6 | Zoom 125 % puis 150 % (`Ctrl` `+`) | Mise en page correcte, rien de coupé | ☐ | |
| C7 | Windows : « Effets d'animation » désactivés | Aucune animation de déplacement ; effets allégés | ☐ | |
| C8 | `edge://settings/system` → désactiver l'accélération matérielle, relancer Edge | Interface identique en verre CSS (pas d'erreur visible) | ☐ | |

## D. Performance

| # | Action | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| D1 | Taper rapidement dans la recherche | Suggestions instantanées ; le pied de liste affiche le temps serveur (< 100 ms) | ☐ | |
| D2 | Ouvrir un groupe | Affichage < 300 ms | ☐ | |
| D3 | Déplier les assignations globales (~300 lignes) et défiler vite (molette, `Page↓`, `Fin`) | Défilement fluide ; F12 → onglet Éléments : jamais plus de ~60 lignes `vt-row` | ☐ | |

## E. Clavier et lecteur d'écran

| # | Action | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| E1 | Tout parcourir avec `Tab` / `Maj+Tab` | Focus toujours visible, ordre logique | ☐ | |
| E2 | Dans le tableau : `↑ ↓ Page↑ Page↓ Début Fin`, `Entrée`, `←/→` sur une section | Navigation ligne par ligne ; `Entrée` ouvre le détail | ☐ | |
| E3 | Sélecteur « Groupe Entra / Configuration » : `←/→` | Bascule ; le texte d'aide du champ change | ☐ | |
| E4 | Menus (pastille d'état, ⚙) : flèches, `Échap` | Navigation au clavier, `Échap` rend le focus au bouton | ☐ | |
| E5 | Narrateur Windows (`Ctrl+Win+Entrée`) sur la recherche et le tableau | Champ annoncé comme zone de liste modifiable ; lignes et cellules annoncées | ☐ | |

## F. États et erreurs

Chaque ligne demande de relancer l'outil avec un paramètre de démonstration.

| # | Lancement | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| F1 | `-Mock -DemoState syncing` | Pastille « Synchronisation 63 % », point bleu animé | ☐ | |
| F2 | `-Mock -DemoState throttled` | « Microsoft ralentit les requêtes, reprise automatique », point orange | ☐ | |
| F3 | `-Mock -DemoState error` | « Échec de la dernière synchronisation », point rouge | ☐ | |
| F4 | `-Mock -DemoState stale` | Bandeau « données de plus de 24 h » | ☐ | |
| F5 | Pastille d'état → menu | Dates, durée, actions de synchro ; « Non couvert : Autopilot, Inscription / ESP » | ☐ | |
| F6 | Menu → Synchronisation incrémentale (ou `R`) | « Synchronisation incrémentale lancée. » ; la pastille affiche la progression ; à la fin, « Données mises à jour : … » | ☐ | |
| F6b | `R` deux fois rapidement | Le 2e appui affiche « Une synchronisation est déjà en cours. » | ☐ | |
| F6c | `Maj+R` | Synchronisation complète (environ 10 s en démo), l'interface reste utilisable pendant ce temps | ☐ | |
| F7 | `Ctrl+C` dans la console PowerShell | Dans les 15 s : « Serveur arrêté » ; après relance de l'outil, « Réessayer » sur l'ancien onglet reste en erreur de session (normal : nouveau jeton) | ☐ | |
| F8 | `F5` dans Edge | « Session invalide » (le jeton n'est gardé qu'en mémoire, spec 5.8) | ☐ | |
| F9 | ⚙ → « Arrêter l'outil » | Confirmation, puis « Outil arrêté » ; la console PowerShell se termine | ☐ | |
| F10 | F12 → onglet Réseau, recharger via la console | Uniquement des requêtes vers `127.0.0.1` | ☐ | |

## G. Cache et synchronisation incrémentale (jalon M3)

| # | Action | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| G1 | Menu de la pastille → « Effacer le cache local », puis arrêter et relancer `-Mock` | « Aucun cache utilisable » dans la console ; l'interface affiche « Première synchronisation… » puis les données (environ 10 s) | ☐ | |
| G2 | Relancer `-Mock` | Les données s'affichent **tout de suite** (« Données du … ») ; une synchro incrémentale rapide suit | ☐ | |
| G3 | Arrêter, puis relancer avec `-Mock -MockDataset modified` | Données du cache affichées, puis le message « Données mises à jour : 5 nouveaux, 6 modifiés, 5 supprimés » ; le menu de la pastille montre « 11 éléments relus » | ☐ | |
| G4 | Pendant une synchro complète (`Maj+R`), fermer brutalement la fenêtre PowerShell, puis relancer | Les données de la dernière synchro réussie sont affichées, sans erreur | ☐ | |
| G5 | Ouvrir `%LOCALAPPDATA%\IntuneAssignLens\cache` dans l'Explorateur, puis Propriétés → Sécurité | Seul votre compte a accès. Le fichier `.dat` est illisible (chiffré) | ☐ | |
| G6 | Remplacer `cache-mock.dat` par un fichier texte quelconque (même nom), puis relancer | Avertissement « Cache illisible ou corrompu : ignoré » dans la console, puis synchro complète normale | ☐ | |

## I. Comparer

| # | Action | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| I1 | Ouvrir un groupe → « Comparer » | Pastille « Comparer » dans la recherche, sélecteur Groupe/Configuration grisé, seuls des groupes proposés (sans le groupe courant) | ☐ | |
| I2 | Choisir un 2e groupe | Écran A ⇄ B, compteurs Tous / Écarts / Seulement A / Seulement B / Différents / Identiques cohérents | ☐ | |
| I3 | Cliquer ⇄ puis « Fermer » | Colonnes inversées ; « Fermer » revient au groupe A | ☐ | |
| I4 | Même chose depuis un élément (configuration) | Seuls des éléments proposés ; lignes = groupes | ☐ | |
| I5 | « Comparer » puis `Échap` | « Comparaison annulée », recherche normale | ☐ | |
| I6 | Fenêtre étroite (~700 px) | Pas de chevauchement ; noms tronqués avec « … » | ☐ | |
| I7 | Exporter CSV depuis la comparaison | Fichier « Comparaison - A vs B.csv » avec colonnes A, B, Écart | ☐ | |

## J. Fiches Utilisateur / Machine

| # | Action | Résultat attendu | OK | Remarque |
|---|---|---|---|---|
| J1 | Lancer l'outil (mode réel) après la mise à jour | Une fenêtre Microsoft peut demander le consentement à **Device.Read.All** (une fois). Refus possible : l'outil démarre quand même | ☐ | |
| J2 | Sélecteur « Utilisateur » (ou touche U), taper un nom | Suggestions : nom, identifiant, nombre d'appareils | ☐ | |
| J3 | Ouvrir un utilisateur qui a deux PC (dont un ancien) | Onglet Appareils : l'ancien PC marqué « Inactif » ; onglet Configurations : pastilles « Tous ses appareils » ou nom du PC | ☐ | |
| J4 | Comparer avec le portail Intune une configuration ciblée par un **groupe d'appareils** | Elle n'apparaît que sur le PC membre du groupe | ☐ | |
| J5 | Onglet Groupes d'un utilisateur avec plus de 20 groupes | 20 par page, pages 1 · 2 · 3 en bas ; groupes utilisés dans Intune en premier | ☐ | |
| J6 | Sélecteur « Machine » (touche M), ouvrir un PC | Utilisateur principal cliquable ; colonne « Ciblage » : Utilisateur / Appareil | ☐ | |
| J7 | Comparer deux utilisateurs, puis deux machines | Éléments et groupes Entra alignés, écarts surlignés | ☐ | |
| J8 | Si Device.Read.All a été refusée : ouvrir une machine | Bandeau « Données partielles » : groupes de la machine indisponibles ; les éléments ciblés via l'utilisateur restent affichés | ☐ | |
| J9 | Sur une fiche, « Copier le lien », revenir à l'accueil, Ctrl+V | La même fiche s'ouvre ; collé au milieu d'un texte (« voir intune-lens://… »), le lien est aussi reconnu | ☐ | |

## H. Reporté

Ces points de la spec 9.4 seront testés plus tard :

| Point | Jalon |
|---|---|
| Bascule Mock / réel | M6 |
| Verre WebGL réel et gouverneur de FPS | M0 |
