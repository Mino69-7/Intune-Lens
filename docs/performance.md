# Mesures de performance (spec §8)

Mesuré le 2026-11-12 en **mode Mock** : 13 002 groupes, 2 035 objets, environ 6 000 assignations. Poste : Windows 11, PowerShell 7.6.9, sans accès réseau.
Les durées Graph réelles (latence, throttling) seront mesurées au jalon M6.

| Mesure | Cible (§8) | Mesuré (Mock) | Verdict |
|---|---|---|---|
| Affichage de la page depuis un cache existant | < 1 s après l'ouverture d'Edge | Edge s'ouvre **après** le chargement du cache : la page affiche les données dès son premier appel à `/api/status`. Lancement complet (démarrage de `pwsh`, lecture du cache, index) : **3,3 s** | ✅ (au sens de la spec) |
| Recherche sur 13 000 groupes | < 100 ms serveur, < 200 ms perçus | **1 à 39 ms** serveur ; aller-retour HTTP **2 à 49 ms** | ✅ |
| Ouverture d'un groupe | < 300 ms | **25 ms** médian, 51 ms au maximum (groupe de référence) | ✅ |
| Défilement d'un résultat de 500 lignes | ≥ 50 FPS | Tableau virtualisé (60 lignes DOM au maximum). **À mesurer dans Edge** (checklist D3) et au spike M0 avec le verre WebGL | ⏳ |
| Synchro incrémentale sans changement | quelques secondes | **3,4 s**, 43 requêtes, 0 assignation relue | ✅ |
| Première synchro complète | mesurée et affichée | **4,5 s** en Mock (147 requêtes). Durée affichée dans le menu de la pastille et dans le journal | ✅ (Mock) / ⏳ réel |
| Mémoire du serveur PowerShell | à mesurer | **355 à 390 Mo** (working set) | voir ci-dessous |

## Mémoire

Les 355 à 390 Mo en Mock comprennent :
- l'exécution de PowerShell 7 (environ 100 Mo à vide) ;
- l'index (13 000 groupes et 2 000 objets) ;
- les **fixtures Mock chargées deux fois** : une fois dans le runspace serveur, une fois dans celui de la synchro (environ 3 Mo de JSON chacune, décuplés une fois en objets PowerShell).

En mode réel, il n'y a pas de fixtures : la mémoire attendue est **plus basse**. Seuil d'alerte proposé : **1 Go**. À mesurer en M6 (Gestionnaire des tâches → `pwsh.exe`).

## Optimisations déjà faites

| Étape | Avant | Après | Moyen |
|---|---|---|---|
| Recherche | 100 à 440 ms | < 40 ms | `String.IndexOf` natif sur un bloc concaténé, avec un budget de candidats |
| Construction de l'index | 5,7 s | 1,15 s | Normalisation des clés en un seul passage natif |
| Démarrage depuis le cache | 8,2 s | 2,6 à 3,3 s | Index plus rapide |
| Pagination des groupes (Mock) | 122 pages | 14 pages | `nextLink` conserve `$top` |

## Comment reproduire

Lancez `pwsh -File .\tests\Run-Tests.ps1` : il contrôle les budgets de recherche (< 100 ms) et d'ouverture (< 300 ms). Les autres mesures sont visibles dans le journal (`%LOCALAPPDATA%\IntuneAssignLens\logs`) et dans le menu de la pastille d'état.
