// i18n.js : interface text (English by default, French) and formatting. No display logic here.
//
// The language is chosen by the server, which writes it into <html data-lang="…"> from the saved settings
// (%LOCALAPPDATA%\IntuneAssignLens\prefs.json), so it survives a full restart of the tool. Changing it
// reloads the page. Every string sits next to its translation: L('français', 'English').

function detectLang() {
  try {
    const forced = globalThis.IAL_LANG;   // tests (node --test)
    if (forced === 'fr' || forced === 'en') return forced;
    return globalThis.document?.documentElement?.dataset?.lang === 'fr' ? 'fr' : 'en';
  } catch { return 'en'; }
}

export const LANG = detectLang();
export const LOCALE = LANG === 'fr' ? 'fr-FR' : 'en-US';

/** Text in the current language. */
export const L = (fr, en) => (LANG === 'fr' ? fr : en);

// Texts produced by the server (error messages, warnings, assignment labels). The server keeps a single
// language (its data and cache stay language-neutral); the interface translates them here.
const SRV_EXACT = {
  'Méthode non autorisée.': 'Method not allowed.',
  'Mode de synchronisation invalide.': 'Invalid sync mode.',
  'Une synchronisation est déjà en cours.': 'A sync is already running.',
  'Données en cours de chargement.': 'Data is loading.',
  'Recherche trop longue.': 'Search text too long.',
  'Paramètre kind invalide.': 'Invalid kind parameter.',
  'Paramètre limit invalide.': 'Invalid limit parameter.',
  'Utilisateur introuvable.': 'User not found.',
  'Machine introuvable.': 'Device not found.',
  'Groupe introuvable.': 'Group not found.',
  'Élément introuvable.': 'Item not found.',
  'Route inconnue.': 'Unknown route.',
  'Introuvable.': 'Not found.',
  'Hôte refusé.': 'Host refused.',
  'Origine refusée.': 'Origin refused.',
  'Requête inter-sites refusée.': 'Cross-site request refused.',
  'Chemin refusé.': 'Path refused.',
  'Requête trop volumineuse.': 'Request too large.',
  "Session invalide. Relancez l'outil.": 'Invalid session. Restart the tool.',
  'Erreur interne. Consultez le journal local.': 'Internal error. Check the local log.',
  'Paramètres invalides.': 'Invalid settings.',
  'Microsoft Graph limite les requêtes : réessayez dans un instant.': 'Microsoft Graph is throttling requests: try again in a moment.',
  'Lecture des groupes impossible pour le moment. Consultez le journal local.': 'The groups cannot be read right now. Check the local log.',
  'Arrêt en cours.': 'Stopping.',
  "Synchronisation lancée (mode premier plan : l'interface ne répondra pas jusqu'à la fin).": 'Sync started (foreground mode: the interface will not respond until it finishes).',
  'Synchronisation complète lancée.': 'Full sync started.',
  'Synchronisation incrémentale lancée.': 'Incremental sync started.',
  "Cache local effacé. Les données restent affichées jusqu'à l'arrêt de l'outil.": 'Local cache cleared. The data stays on screen until the tool stops.',
  'Aucun cache local à effacer.': 'No local cache to clear.',
  'La dernière synchronisation a échoué. Consultez le journal local.': 'The last sync failed. Check the local log.',
  'Accès refusé par Graph (403)': 'Access denied by Graph (403)',
  'Accès refusé (403) aux groupes de cet utilisateur.': "Access denied (403) to this user's groups.",
  'Appareil introuvable dans Entra (404).': 'Device not found in Entra (404).',
  'Utilisateur introuvable dans Entra (404).': 'User not found in Entra (404).',
  'Appareil non joint à Entra : ses groupes ne sont pas lisibles.': 'Device not joined to Entra: its groups cannot be read.',
  'Groupe direct': 'Direct group',
  'Tous les utilisateurs': 'All users',
  'Tous les appareils': 'All devices',
  "Groupe (balise d'étendue)": 'Group (scope tag)',
  'Lecture des groupes': 'Reading groups',
  'Lecture des listes': 'Reading lists',
  'Lecture des assignations': 'Reading assignments',
  "Construction de l'index": 'Building the index',
  'Enregistrement du cache': 'Saving the cache',
};
const SRV_PATTERNS = [
  [/^Groupes de l'utilisateur : (.+)$/s, (m) => `User's groups: ${srv(m[1])}`],
  [/^(.+) : appareil non joint à Entra, ses groupes ne sont pas lisibles\.$/s, (m) => `${m[1]}: device not joined to Entra, its groups cannot be read.`],
  [/^Permission (\S+) non accordée : groupes de la machine indisponibles\.$/, (m) => `Permission ${m[1]} not granted: device groups unavailable.`],
  [/^Accès refusé \(403\) : la permission (\S+) est nécessaire pour les groupes des machines\.$/, (m) => `Access denied (403): the ${m[1]} permission is needed for device groups.`],
  [/^Lecture impossible \(HTTP (\d+)\)\.$/, (m) => `Cannot be read (HTTP ${m[1]}).`],
  [/^Activé, mais le jeton ne contient pas (.+)$/, (m) => `Enabled, but the token does not contain ${m[1]}`],
  [/^Permission (\S+) déjà présente dans le jeton : activable avec (.+)$/, (m) => `Permission ${m[1]} already in the token: can be enabled with ${m[2]}`],
  [/^Permission non consentie \((.+)\)$/, (m) => `Permission not granted (${m[1]})`],
  [/^Cible non prise en charge \((.*)\)$/, (m) => `Unsupported target (${m[1] === 'inconnu' ? 'unknown' : m[1]})`],
  [/^Groupe supprimé \((.*)\)$/, (m) => `Deleted group (${m[1]})`],
  [/^Filtre inconnu \((.*)\)$/, (m) => `Unknown filter (${m[1]})`],
  [/^(.+) \(utilisateur\)$/s, (m) => `${m[1]} (user)`],
  [/^(.+) \(appareil\)$/s, (m) => `${m[1]} (device)`],
  [/^(.+?) : (.+)$/s, (m) => { const r = srv(m[2]); return r === m[2] ? null : `${m[1]}: ${r}`; }],   // "<device> : <reason>"
];
/** Server text in the current language (the server writes French). */
export function srv(text) {
  const s = String(text ?? '');
  if (LANG === 'fr' || !s) return s;
  if (Object.hasOwn(SRV_EXACT, s)) return SRV_EXACT[s];
  for (const [re, fn] of SRV_PATTERNS) {
    const m = re.exec(s);
    if (m) { const out = fn(m); if (out !== null) return out; }
  }
  return s;
}

/** Server message: plain string (translated by srv), or { fr, en }. */
export function tx(v) {
  if (v && typeof v === 'object') return String(v[LANG] ?? v.en ?? v.fr ?? '');
  return v == null ? '' : srv(v);
}

const nf = new Intl.NumberFormat(LOCALE);
const dfShort = new Intl.DateTimeFormat(LOCALE, LANG === 'fr' ? { day: '2-digit', month: '2-digit' } : { month: 'short', day: 'numeric' });
const tfShort = new Intl.DateTimeFormat(LOCALE, { hour: '2-digit', minute: '2-digit' });
const dfLong = new Intl.DateTimeFormat(LOCALE, LANG === 'fr'
  ? { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }
  : { month: 'short', day: 'numeric', year: 'numeric', hour: '2-digit', minute: '2-digit' });

export const fmt = {
  num: (n) => nf.format(Number(n) || 0),
  /** "Data from Nov 12 at 1:13 PM" / « Données du 12/11 à 13:13 » */
  dataAge(iso) {
    const d = iso ? new Date(iso) : null;
    if (!d || isNaN(d)) return L('Aucune donnée', 'No data');
    return L(`Données du ${dfShort.format(d)} à ${tfShort.format(d)}`, `Data from ${dfShort.format(d)} at ${tfShort.format(d)}`);
  },
  date(iso) {
    const d = iso ? new Date(iso) : null;
    return !d || isNaN(d) ? '—' : dfLong.format(d);
  },
  /** Short date + time (status pill). */
  shortDateTime(iso) {
    const d = iso ? new Date(iso) : null;
    return !d || isNaN(d) ? '—' : `${dfShort.format(d)} ${tfShort.format(d)}`;
  },
  plural(n, one, many) { return `${nf.format(n)} ${Math.abs(n) <= 1 ? one : many}`; },
  /** "today", "yesterday", "12 days ago" */
  ago(iso, now = Date.now()) {
    const d = iso ? new Date(iso) : null;
    if (!d || isNaN(d)) return '—';
    const days = Math.floor((now - d.getTime()) / 86400000);
    if (days <= 0) return L("aujourd'hui", 'today');
    if (days === 1) return L('hier', 'yesterday');
    return L(`il y a ${nf.format(days)} j`, `${nf.format(days)} days ago`);
  },
  daysSince(iso, now = Date.now()) {
    const d = iso ? new Date(iso) : null;
    return !d || isNaN(d) ? null : Math.max(0, Math.floor((now - d.getTime()) / 86400000));
  },
};

export const T = {
  appName: 'Intune Lens',
  searchPlaceholder: {
    user: L('Rechercher un utilisateur (nom ou identifiant)', 'Search for a user (name or sign-in name)'),
    device: L('Rechercher une machine (nom ou n° de série)', 'Search for a device (name or serial number)'),
    group: L('Rechercher un groupe Entra', 'Search for an Entra group'),
    object: L('Rechercher une configuration, une application…', 'Search for a configuration, an app…'),
  },
  kindLabel: {
    user: L('Utilisateur', 'User'), device: L('Machine', 'Device'),
    group: L('Groupe Entra', 'Entra group'), object: L('Configuration', 'Configuration'),
  },
  comparePlaceholder: {
    user: L('Comparer avec un autre utilisateur…', 'Compare with another user…'),
    device: L('Comparer avec une autre machine…', 'Compare with another device…'),
    group: L('Comparer avec un autre groupe Entra…', 'Compare with another Entra group…'),
    object: L('Comparer avec une autre configuration…', 'Compare with another configuration…'),
  },
  compliance: {
    compliant: L('Conforme', 'Compliant'), noncompliant: L('Non conforme', 'Not compliant'),
    inGracePeriod: L('Période de grâce', 'In grace period'), conflict: L('Conflit', 'Conflict'),
    error: L('Erreur', 'Error'), unknown: L('Inconnu', 'Unknown'), configManager: 'Configuration Manager',
  },
  targetingNote: L(
    "Ciblage calculé à partir des assignations et des groupes Entra : l'état réel de déploiement (réussi, en erreur) n'est pas lu, "
      + "et les filtres d'assignation ne sont pas évalués (signalés « filtre »).",
    'Targeting is computed from assignments and Entra groups: the actual deployment state (succeeded, failed) is not read, '
      + 'and assignment filters are not evaluated (shown as "filter").',
  ),
  mode: { include: L('Inclus', 'Included'), exclude: L('Exclu', 'Excluded') },
  intent: {
    required: L('Obligatoire', 'Required'),
    available: L('Disponible', 'Available'),
    uninstall: L('Désinstaller', 'Uninstall'),
    availableWithoutEnrollment: L('Disponible sans inscription', 'Available without enrollment'),
  },
  filterMode: { include: L('inclure', 'include'), exclude: L('exclure', 'exclude') },
  via: {
    direct: L('Groupe direct', 'Direct group'),
    allUsers: L('Tous les utilisateurs', 'All users'),
    allLicensedUsers: L('Tous les utilisateurs', 'All users'),
    allDevices: L('Tous les appareils', 'All devices'),
  },
  phase: {
    idle: L('En attente', 'Waiting'),
    groups: L('Lecture des groupes', 'Reading groups'),
    lists: L('Lecture des listes', 'Reading lists'),
    assignments: L('Lecture des assignations', 'Reading assignments'),
    indexing: L("Construction de l'index", 'Building the index'),
    saving: L('Enregistrement du cache', 'Saving the cache'),
    done: L('À jour', 'Up to date'),
    error: L('Échec de la synchronisation', 'Sync failed'),
  },
  globalNote: L(
    "Assignations globales (indicatif) : ces règles visent « Tous les utilisateurs » ou « Tous les appareils ». "
      + "Elles s'appliquent potentiellement à ce groupe selon le type de ses membres, ce que la v1 ne calcule pas. "
      + 'Les exclusions de ce groupe sur ces règles sont signalées.',
    'Global assignments (for information): these rules target "All users" or "All devices". '
      + 'They may apply to this group depending on its member type, which this version does not compute. '
      + "This group's exclusions from these rules are shown.",
  ),
  errors: {
    network: {
      title: L('Serveur arrêté', 'Server stopped'),
      text: L("L'outil local ne répond plus. Relancez Intune Lens puis rouvrez la page.", 'The local tool is no longer responding. Start Intune Lens again, then reopen the page.'),
    },
    session: {
      title: L('Session invalide', 'Invalid session'),
      text: L(
        "Le lien de session n'est plus valable (page rechargée ou outil relancé). Relancez Intune Lens : il rouvre Edge avec un nouveau lien.",
        'The session link is no longer valid (page reloaded or tool restarted). Start Intune Lens again: it reopens Edge with a new link.',
      ),
    },
    generic: L('Une erreur est survenue. Consultez le journal local.', 'Something went wrong. Check the local log.'),
  },
};

// Intune families: the server sends the French name (stable internal key); translated for display.
const FAMILY_EN = {
  Appareils: 'Devices',
  Applications: 'Apps',
  Autopilot: 'Autopilot',
  'Catalogue de paramètres': 'Settings catalog',
  'Configuration (modèles)': 'Configuration (templates)',
  "Configuration d'application": 'App configuration',
  Conformité: 'Compliance',
  'Inscription / ESP': 'Enrollment / ESP',
  'Mises à jour de fonctionnalités': 'Feature updates',
  'Mises à jour de pilotes': 'Driver updates',
  'Mises à jour qualité': 'Quality updates',
  "Modèles d'administration (ADMX)": 'Administrative templates (ADMX)',
  "Protection d'application": 'App protection',
  Remédiations: 'Remediations',
  'Scripts PowerShell': 'PowerShell scripts',
  'Sécurité des points de terminaison': 'Endpoint security',
  'Groupes Entra': 'Entra groups',
  'Bases de référence de sécurité': 'Security baselines',
  'Appareils (fiches Utilisateur / Machine)': 'Devices (User / Device pages)',
  'Exclusions sur règles globales': 'Exclusions from global rules',
  Configuration: 'Configuration',
  'Assignations globales (indicatif)': 'Global assignments (for information)',
  'Cibles globales': 'Global targets',
  Groupes: 'Groups',
  'Autres cibles': 'Other targets',
};
export function familyLabel(family) {
  const f = String(family ?? '');
  return LANG === 'fr' ? f : FAMILY_EN[f] || f;
}

// Readable labels for the most common OData types; fallback: split the technical name.
const TYPE_LABELS = {
  win32LobApp: ['Application Win32', 'Win32 app'],
  winGetApp: ['Microsoft Store (nouveau)', 'Microsoft Store app (new)'],
  officeSuiteApp: ['Microsoft 365 Apps', 'Microsoft 365 Apps'],
  windowsMicrosoftEdgeApp: ['Microsoft Edge', 'Microsoft Edge'],
  win32CatalogApp: ['Application Win32 (catalogue)', 'Win32 app (catalog)'],
  windowsUniversalAppX: ['Application Windows (AppX / MSIX)', 'Windows app (AppX / MSIX)'],
  windowsMobileMSI: ['Application Windows (MSI)', 'Windows app (MSI)'],
  windowsStoreApp: ['Microsoft Store (ancien)', 'Microsoft Store app (legacy)'],
  windowsWebApp: ['Lien web Windows', 'Windows web link'],
  microsoftStoreForBusinessApp: ['Microsoft Store Entreprise', 'Microsoft Store for Business'],
  iosVppApp: ['Application iOS (VPP)', 'iOS app (VPP)'],
  iosStoreApp: ['Application iOS (Store)', 'iOS store app'],
  androidManagedStoreApp: ['Android Enterprise (Play géré)', 'Managed Google Play app'],
  webApp: ['Lien web', 'Web link'],
  macOSLobApp: ['Application macOS (LOB)', 'macOS LOB app'],
  windows10GeneralConfiguration: ['Restrictions Windows', 'Windows device restrictions'],
  windows10EndpointProtectionConfiguration: ['Endpoint Protection Windows', 'Windows Endpoint Protection'],
  windows10CustomConfiguration: ['Personnalisé (OMA-URI)', 'Custom (OMA-URI)'],
  iosDeviceFeaturesConfiguration: ['Fonctionnalités iOS', 'iOS device features'],
  androidWorkProfileGeneralDeviceConfiguration: ['Android profil professionnel', 'Android work profile'],
  macOSCustomConfiguration: ['Personnalisé macOS', 'macOS custom'],
  deviceManagementConfigurationPolicy: ['Catalogue de paramètres', 'Settings catalog'],
  groupPolicyConfiguration: ['Modèle ADMX', 'ADMX template'],
  windows10CompliancePolicy: ['Conformité Windows', 'Windows compliance'],
  iosCompliancePolicy: ['Conformité iOS', 'iOS compliance'],
  androidWorkProfileCompliancePolicy: ['Conformité Android', 'Android compliance'],
  macOSCompliancePolicy: ['Conformité macOS', 'macOS compliance'],
  deviceManagementScript: ['Script PowerShell', 'PowerShell script'],
  deviceHealthScript: ['Remédiation', 'Remediation'],
  deviceManagementIntent: ['Sécurité (intent)', 'Security (intent)'],
  windowsFeatureUpdateProfile: ['Mise à jour de fonctionnalités', 'Feature update'],
  windowsQualityUpdateProfile: ['Mise à jour qualité', 'Quality update'],
  windowsDriverUpdateProfile: ['Mise à jour de pilotes', 'Driver update'],
  iosManagedAppProtection: ["Protection d'application iOS", 'iOS app protection'],
  androidManagedAppProtection: ["Protection d'application Android", 'Android app protection'],
  targetedManagedAppConfiguration: ["Configuration d'application", 'App configuration'],
};

export function typeLabel(odataType) {
  const t = String(odataType || '').replace(/^#microsoft\.graph\./, '');
  if (!t) return '—';
  if (TYPE_LABELS[t]) return L(...TYPE_LABELS[t]);
  return t.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/^./, (c) => c.toUpperCase());
}

export function filterLabel(filter) {
  if (!filter) return '';
  const m = T.filterMode[filter.mode] || filter.mode || '';
  const name = srv(filter.name);
  return m ? `${name} (${m})` : name;
}

export function intentLabel(intent) {
  return intent ? T.intent[intent] || intent : '';
}
