<img src="web/img/logo.svg" width="72" alt="Logo Intune Lens">

# IntuneAssignLens

**Intune Lens** (projet IntuneAssignLens) : outil local, **en lecture seule**, qui répond à deux questions sur Intune :

- **Utilisateur / Machine** : quels groupes et quelles configurations visent cette personne, PC par PC, ou ce poste ?
- **Groupe vers éléments** : qu'est-ce qui est assigné à ce groupe Entra (configurations, conformités, applications, scripts…) ?
- **Élément vers groupes** : à quels groupes cet élément est-il assigné, en inclusion ou en exclusion ?

L'interface s'ouvre dans Microsoft Edge. Elle est servie par un petit serveur PowerShell qui n'écoute que sur `127.0.0.1`. Aucune donnée ne quitte le poste, hormis les lectures vers Microsoft Graph.

> **État** : utilisable sur un tenant réel, en lecture seule. Recherche par utilisateur, machine, groupe Entra ou configuration.

---

## 1. Prérequis

| Élément | Détail |
|---|---|
| Système | Windows 10 ou 11, Microsoft Edge à jour |
| PowerShell | **PowerShell 7** (`pwsh`). `Installer.cmd` propose de l'installer s'il manque. Windows PowerShell 5.1 est refusé avec un message clair. |
| Mode de langage | `FullLanguage`. En mode restreint (WDAC / AppLocker), l'outil s'arrête et explique pourquoi. |
| Module Graph (mode réel uniquement) | `Microsoft.Graph.Authentication`. `Installer.cmd` propose de l'installer pour votre compte. L'outil lui-même n'installe jamais rien. |
| Droits locaux | **Aucun droit administrateur.** Pas de service, pas de tâche planifiée, pas de registre. |
| Rôles Entra / Intune | Lecture des objets Intune et des groupes : par exemple Global Reader ou Intune Administrator. |
| Tenant | **N'importe lequel** : l'outil se connecte au tenant du compte avec lequel vous vous connectez. Rien n'est propre à une organisation. |

## 2. Installation (une seule fois)

1. Sur la page GitHub : **Code** → **Download ZIP**.
   *Astuce : clic droit sur le ZIP → **Propriétés** → cochez **Débloquer** → OK. Windows n'affichera alors aucun avertissement.*
2. Clic droit sur le ZIP → **Extraire tout…**, vers un dossier durable, par exemple `Documents\Intune-Lens`.
3. Dans ce dossier, double-cliquez **`Installer.cmd`**.
   - Si Windows affiche « Windows a protégé votre ordinateur » : **Informations complémentaires** → **Exécuter quand même**.
   - Il trouve PowerShell 7 (ou propose de l'installer avec `winget`), débloque les fichiers du dossier, propose d'installer le module `Microsoft.Graph.Authentication` **pour votre compte** (sans droits administrateur), puis crée le raccourci **Intune Lens** avec le logo sur le **Bureau** et dans le **menu Démarrer**.
4. Double-cliquez **Intune Lens**. Connectez-vous avec votre compte Microsoft professionnel : l'outil s'ouvre dans Edge, sur votre tenant.

Ce que l'installation ne fait **pas** : pas de droits administrateur, pas de registre, pas de tâche planifiée, pas de service. Elle ne contourne jamais la stratégie d'exécution (pas de `-ExecutionPolicy Bypass`) : elle retire seulement la marque « téléchargé d'Internet » des fichiers du dossier. Sur un poste où la stratégie est `AllSigned` ou `Restricted`, elle s'arrête et le dit.

- **Mise à jour** : téléchargez le nouveau ZIP, remplacez le contenu du dossier, relancez `Installer.cmd`.
- **Avec Git** : `git clone https://github.com/Mino69-7/Intune-Lens.git`, puis `Installer.cmd`.
- **Dossier déplacé** : relancez `Installer.cmd`, il recrée le raccourci.
- **Désinstallation** : `pwsh -File .\setup\Install-IntuneLens.ps1 -Uninstall` (retire les raccourcis, propose d'effacer le cache), puis supprimez le dossier.

## 3. Démarrage

### Mode démo (données fictives, aucun réseau)

```powershell
pwsh -File .\Start-IntuneAssignLens.ps1 -Mock
```

### Mode réel (votre tenant)

```powershell
pwsh -File .\Start-IntuneAssignLens.ps1
pwsh -File .\Start-IntuneAssignLens.ps1 -TenantId <id-du-tenant>   # pour forcer un tenant
```

1. Une fenêtre de connexion Microsoft s'ouvre. Connectez-vous avec votre compte professionnel : l'outil lit le tenant de ce compte.
2. **Premier lancement sur un tenant** : Microsoft peut afficher « Autorisations demandées » pour **Microsoft Graph Command Line Tools**, l'application officielle du module Microsoft Graph.
   - Vérifiez qu'il ne liste que les permissions de **lecture** du §5.
   - Les permissions Intune exigent un **consentement administrateur**. Si vous n'êtes pas administrateur, l'écran propose de demander l'approbation ; sinon, demandez à un administrateur Entra (Administrateur d'application cloud ou Administrateur général) d'accepter une fois pour l'organisation.
   - Si seule `Device.Read.All` est refusée, l'outil démarre quand même (voir §5).
3. Edge s'ouvre sur l'interface. Au premier lancement, la synchronisation complète se fait en arrière-plan, et sa progression s'affiche dans la pastille en haut à droite.
4. `Ctrl+C` dans la console, ou ⚙ → « Arrêter l'outil », arrête le serveur et ferme la session Graph.

### Lancer en un double-clic

`Installer.cmd` crée le raccourci **Intune Lens** (Bureau et menu Démarrer). Il lance `pwsh -NoProfile -File "<dossier>\Start-IntuneAssignLens.ps1" -PauseOnError` : si le démarrage échoue, la fenêtre reste ouverte avec le message.
- Le raccourci n'est pas versionné (`.gitignore`) : il contient des chemins propres à votre poste.
- **Épingler au menu Démarrer** : Démarrer → Toutes les applications → clic droit sur « Intune Lens » → « Épingler à l'écran de démarrage ». Ou clic droit sur le raccourci du bureau → « Épingler à l'écran de démarrage ».
- **Épingler à la barre des tâches** : clic droit sur le raccourci → « Afficher d'autres options » → « Épingler à la barre des tâches ».
- La fenêtre PowerShell **doit rester ouverte** pendant l'utilisation : la fermer arrête l'outil.
- Un favori dans Edge ne fonctionne pas : le port et le jeton de session changent à chaque lancement.
- Si vous déplacez le dossier du projet, relancez `Installer.cmd`.

### Paramètres

| Paramètre | Effet |
|---|---|
| `-Mock` | Données fictives de `mock/fixtures`, aucune connexion. |
| `-NoBrowser` | N'ouvre pas Edge ; l'adresse à ouvrir s'affiche dans la console. |
| `-Port <n>` | Port local fixe (défaut : port libre aléatoire). |
| `-TenantId <id>` | Force le tenant à la connexion. |
| `-NoDiskCache` | N'écrit rien sur disque, ni cache ni journal. |
| `-PauseOnError` | En cas d'erreur, attend Entrée avant de fermer la fenêtre (utilisé par le raccourci). |
| `-EnableOptionalTypes <types>` | Lit aussi `deviceHealthScripts` (Remédiations), `windowsAutopilotDeploymentProfiles` ou `deviceEnrollmentConfigurations`. Ces types exigent une permission hors des 4 scopes : ils ne sont lus **que si votre jeton la contient déjà**. L'outil ne la demande jamais (voir §5). |
| `-MockDataset modified` | Démo : jeu de données « modifié », pour voir la synchronisation incrémentale. |
| `-DemoState syncing\|throttled\|error\|stale` | Démo : simule un état de synchronisation dans l'interface. |

## 4. Utilisation

Le guide illustré se trouve dans [docs/guide-lecture.md](docs/guide-lecture.md).

| Touche | Action |
|---|---|
| `/` | Rechercher |
| `Échap` | Effacer ou fermer |
| `↑` `↓` | Naviguer |
| `Entrée` | Ouvrir |
| `U` / `M` / `G` / `C` | Recherche Utilisateur / Machine / Groupe / Configuration |
| `R` / `Maj+R` | Synchronisation incrémentale / complète |
| `T` | Mode sombre / clair (aussi : ⚙ → interrupteur « Mode sombre ») |

- **Export** : « Exporter CSV » (séparateur `;`, UTF-8, s'ouvre directement dans Excel) ou « Copier le tableau ».
- **Comparer** : sur l'écran d'un groupe ou d'un élément, bouton « Comparer », puis choisissez dans la recherche un deuxième groupe (ou un deuxième élément : le type est verrouillé). Les deux colonnes A et B s'affichent côte à côte ; filtres « Écarts », « Seulement A », « Seulement B », « Différents » (inclus d'un côté, exclu de l'autre). ⇄ inverse A et B, « Fermer » revient à A, `Échap` annule le choix.
- **Fiche Utilisateur** : onglets **Configurations** (avec, pour chaque élément, le ou les PC concernés : « Tous ses appareils », un PC précis, ou exclu sur un PC), **Groupes** (tous ses groupes Entra, ceux utilisés dans Intune en premier, 20 par page) et **Appareils** (dernière synchro, conformité, « Inactif » au-delà de 30 jours). Le filtre « Appareil » limite la liste à un PC.
- **Fiche Machine** : utilisateur principal (cliquable), groupes de la machine, éléments ciblés avec la colonne « Ciblage » (par l'utilisateur ou par l'appareil).
- **Ciblé ≠ appliqué** : les fiches montrent ce que les assignations visent. L'état de déploiement réel (réussi, en erreur) n'est pas lu, et les filtres d'assignation ne sont pas évalués (signalés).
- **Comparer** fonctionne aussi entre deux utilisateurs ou deux machines (éléments ciblés + groupes Entra).
- **Partager une fiche** : bouton **Copier le lien** en haut de chaque fiche. Il copie un lien `intune-lens://user/<identifiant>` (type + identifiant Microsoft, rien d'autre). Le collègue qui a Intune Lens le **colle (Ctrl+V)** n'importe où dans l'outil : la fiche s'ouvre. Le lien n'est pas cliquable (Teams, e-mail) : cela exigerait d'inscrire un protocole dans le registre Windows, ce que l'outil s'interdit. Le collègue ne voit que ce que ses propres droits Intune lui permettent de lire.
- **Assignations globales** (Tous les utilisateurs / Tous les appareils) : affichées à titre **indicatif** sur l'écran d'un groupe. La v1 ne calcule pas l'appartenance réelle des membres.

## 5. Droits Microsoft Graph

L'outil demande **uniquement** ces 5 permissions déléguées de **lecture** :

| Permission | Pour lire |
|---|---|
| `DeviceManagementConfiguration.Read.All` | Configurations, catalogue de paramètres, ADMX, conformité, scripts PowerShell, sécurité, mises à jour, filtres |
| `DeviceManagementApps.Read.All` | Applications, protection et configuration d'application |
| `DeviceManagementManagedDevices.Read.All` | Appareils gérés et leur utilisateur principal (fiches Utilisateur / Machine) |
| `Group.Read.All` | Noms des groupes, groupes d'un utilisateur |
| `Device.Read.All` | Groupes d'une machine (objet appareil Entra) |

- **`Device.Read.All` est facultative.** Elle demande un consentement administrateur, une seule fois. Si elle est refusée, l'outil se connecte avec les 4 autres et fonctionne : seuls les groupes des machines manquent, ce que les fiches signalent (« Données partielles »).

- **Lecture seule par construction.** Toutes les requêtes passent par une fonction unique (`Invoke-GraphRead`) qui refuse :
  - toute méthode autre que GET ;
  - tout hôte autre que `graph.microsoft.com`.

  Seule exception : la requête groupée `$batch` (POST), acceptée uniquement si **chacune** de ses sous-requêtes est un GET. Les tests automatisés prouvent ces refus.
- **Types optionnels.** La documentation Microsoft (vérifiée en M4) exige une autre permission pour les **Remédiations** (`DeviceManagementScripts.Read.All`), **Autopilot** et **Inscription / ESP** (`DeviceManagementServiceConfig.Read.All`). Ces types sont affichés « Non couvert ».
  - Si votre jeton contient déjà la permission (consentement large existant), le menu de la pastille l'indique.
  - Vous pouvez alors les activer avec `-EnableOptionalTypes`.
- Le détail par endpoint, avec les liens vers la documentation, se trouve dans [docs/verifications.md](docs/verifications.md).

## 6. Données, cache et journal

- **Lancements suivants** : les données du cache s'affichent tout de suite (« Données du JJ/MM à HH:MM »). Une synchronisation **incrémentale** suit : seuls les éléments nouveaux ou modifiés sont relus.
- **Synchronisation complète** : automatique si la dernière date de plus d'un jour, ou à la demande (`Maj+R`).
- **Cache** : `%LOCALAPPDATA%\IntuneAssignLens\cache\`.
  - Le fichier est chiffré pour votre compte Windows (DPAPI) et le dossier n'est accessible qu'à votre compte.
  - L'écriture est atomique : une coupure ne corrompt pas le cache.
  - Il contient des noms de configurations et de groupes, **jamais de jeton ni de contenu de script**.
  - Pour l'effacer : menu de la pastille → « Effacer le cache local ».
- **Journal** : `%LOCALAPPDATA%\IntuneAssignLens\logs\ial-AAAAMMJJ.log`, en clair, sans jeton.
- **Démo de l'incrémental** : lancez `-Mock`, arrêtez, puis relancez avec `-Mock -MockDataset modified`.

## 7. Sécurité (résumé)

- Écoute sur `127.0.0.1` uniquement, port aléatoire.
- Accès au serveur local :
  - jeton de session aléatoire de 32 octets, comparé en temps constant ;
  - contrôle des en-têtes `Host`, `Origin` et `Sec-Fetch-Site` ;
  - liste blanche de fichiers.
- En-têtes de réponse :
  - **CSP stricte** sans aucun assouplissement (`'self'` uniquement) ;
  - `Permissions-Policy`, `nosniff`, `no-referrer`.
- Aucune ressource externe : polices système, aucun CDN, aucune télémétrie. Vérifiable dans Edge : F12 → onglet Réseau, seul `127.0.0.1` apparaît.
- Aucune élévation, aucune persistance, aucun processus caché. Le seul processus lancé est Edge, dans une fenêtre visible.
- Résultats des contrôles statiques : section « Static » de `tests/Run-Tests.ps1`.

## 8. Dépannage

| Symptôme | Cause probable | Que faire |
|---|---|---|
| « IntuneAssignLens nécessite PowerShell 7 » | Lancé avec `powershell.exe` (5.1) | Lancez avec `pwsh -File …` |
| « PowerShell est en mode ConstrainedLanguage » | WDAC / AppLocker | Voir avec l'équipe sécurité. L'outil ne contourne rien. |
| « … n'est pas signé numériquement » / « cannot be loaded » | Fichiers marqués comme téléchargés | Relancez `Installer.cmd` (il les débloque), ou `Get-ChildItem -Recurse -File \| Unblock-File` |
| `Installer.cmd` : « Stratégie d'exécution AllSigned / Restricted » | Stratégie imposée par votre organisation | Voir avec votre service informatique : l'outil ne la contourne pas |
| « Module Microsoft.Graph.Authentication introuvable » | Module absent | Relancez `Installer.cmd`, ou `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser` |
| « Approbation de l'administrateur requise » à la connexion | Le tenant n'a pas encore consenti les permissions de lecture (§5) | Demandez à un administrateur Entra de les accepter une fois pour l'organisation |
| « Impossible d'écouter sur 127.0.0.1:… » | Port occupé | Relancez (port aléatoire) ou utilisez `-Port <autre>` |
| Edge ne s'ouvre pas | Edge introuvable | Relancez avec `-NoBrowser` et ouvrez l'adresse affichée |
| « Session invalide » dans la page | Page rechargée (`F5`) ou outil relancé | Fermez l'onglet ; l'outil rouvre Edge avec un nouveau lien à chaque lancement |
| « Serveur arrêté » dans la page | Console PowerShell fermée ou `Ctrl+C` | Relancez l'outil |
| Pastille orange « Microsoft ralentit les requêtes » | Limitation Graph (HTTP 429) | Rien à faire : reprise automatique en respectant le délai demandé par Microsoft |
| Console « Repli : synchronisation au premier plan » | La synchro en arrière-plan ne voit pas la session Graph (point V16) : bascule automatique | Rien à faire. L'interface ne répond pas pendant une synchro. Ouvrez une *issue* sur GitHub. |
| Journal « Assignations illisibles … (HTTP 4xx) » | Endpoint ou permission inattendus | Ouvrez une *issue* sur GitHub avec la ligne (type et code HTTP) |
| Remédiations / Autopilot / ESP absents | Permission hors des 4 scopes | Voir §5 et le menu de la pastille (« activable avec … ») |
| Journal « Cache illisible ou corrompu : ignoré » | Fichier abîmé ou d'une autre version | Rien à faire : une synchronisation complète le remplace |

## 9. Tests

```powershell
pwsh -File .\tests\Run-Tests.ps1
```

Suite autonome, en mode Mock, sans réseau sortant. Elle couvre :
- le garde-fou lecture seule, la collecte (pagination, 429, 5xx), l'inventaire Graph ;
- l'index, la recherche, la synchronisation incrémentale, le cache (coupure simulée) ;
- le serveur local et les contrôles statiques de la spec §9.2.

Si Node.js est présent, la syntaxe JavaScript et la logique de l'interface sont aussi vérifiées. La checklist de test manuel dans Edge se trouve dans [docs/test-manuel.md](docs/test-manuel.md).

## 10. Documentation

| Fichier | Contenu |
|---|---|
| [docs/guide-lecture.md](docs/guide-lecture.md) | Comment lire l'interface |
| [docs/test-manuel.md](docs/test-manuel.md) | Checklist de test dans Edge |
| [docs/verifications.md](docs/verifications.md) | Points vérifiés, inventaire Graph avec sources |
| [docs/decisions.md](docs/decisions.md) | Choix techniques et leurs raisons |
| [docs/performance.md](docs/performance.md) | Mesures par rapport aux budgets de la spec |

## 11. Structure

```
Installer.cmd                installation en un double-clic (raccourci, module Graph)
Start-IntuneAssignLens.ps1   point d'entrée (lancé par le raccourci)
setup/    Install-IntuneLens.ps1 : appelé par Installer.cmd ; -Uninstall pour désinstaller
src/      Config, Log, GraphClient (seul accès réseau + garde-fou), Collectors, Index, Cache, Sync, Server
web/      interface (HTML/CSS/JS natifs, sans build, verre 100 % CSS) ; web/img/logo.svg = icône de l'onglet
assets/   intune-lens.ico : logo du raccourci Windows (16 à 256 px)
mock/     générateur de données fictives déterministe + fixtures
tests/    Run-Tests.ps1 (PowerShell) + tests/web (Node, optionnel)
docs/     documentation
```
