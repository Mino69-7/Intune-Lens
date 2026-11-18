// i18n.fr.js : textes d'interface et formatage (fr-FR). Aucune logique d'affichage ici.

const nf = new Intl.NumberFormat('fr-FR');
const dfShort = new Intl.DateTimeFormat('fr-FR', { day: '2-digit', month: '2-digit' });
const tfShort = new Intl.DateTimeFormat('fr-FR', { hour: '2-digit', minute: '2-digit' });
const dfLong = new Intl.DateTimeFormat('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });

export const fmt = {
  num: (n) => nf.format(Number(n) || 0),
  /** « Données du 12/11 à 13:13 » */
  dataAge(iso) {
    const d = iso ? new Date(iso) : null;
    if (!d || isNaN(d)) return 'Aucune donnée';
    return `Données du ${dfShort.format(d)} à ${tfShort.format(d)}`;
  },
  date(iso) {
    const d = iso ? new Date(iso) : null;
    return !d || isNaN(d) ? '—' : dfLong.format(d);
  },
  plural(n, one, many) { return `${nf.format(n)} ${Math.abs(n) <= 1 ? one : many}`; },
  /** « aujourd'hui », « hier », « il y a 12 j » */
  ago(iso, now = Date.now()) {
    const d = iso ? new Date(iso) : null;
    if (!d || isNaN(d)) return '—';
    const days = Math.floor((now - d.getTime()) / 86400000);
    if (days <= 0) return "aujourd'hui";
    if (days === 1) return 'hier';
    return `il y a ${nf.format(days)} j`;
  },
  daysSince(iso, now = Date.now()) {
    const d = iso ? new Date(iso) : null;
    return !d || isNaN(d) ? null : Math.max(0, Math.floor((now - d.getTime()) / 86400000));
  },
};

export const T = {
  appName: 'Intune Lens',
  searchPlaceholder: {
    user: 'Rechercher un utilisateur (nom ou identifiant)',
    device: 'Rechercher une machine (nom ou n° de série)',
    group: 'Rechercher un groupe Entra',
    object: 'Rechercher une configuration, une application…',
  },
  kindLabel: { user: 'Utilisateur', device: 'Machine', group: 'Groupe Entra', object: 'Configuration' },
  comparePlaceholder: {
    user: 'Comparer avec un autre utilisateur…',
    device: 'Comparer avec une autre machine…',
    group: 'Comparer avec un autre groupe Entra…',
    object: 'Comparer avec une autre configuration…',
  },
  compliance: { compliant: 'Conforme', noncompliant: 'Non conforme', inGracePeriod: 'Période de grâce', conflict: 'Conflit', error: 'Erreur', unknown: 'Inconnu', configManager: 'Configuration Manager' },
  targetingNote:
    "Ciblage calculé à partir des assignations et des groupes Entra : l'état réel de déploiement (réussi, en erreur) n'est pas lu, " +
    "et les filtres d'assignation ne sont pas évalués (signalés « filtre »).",
  mode: { include: 'Inclus', exclude: 'Exclu' },
  intent: {
    required: 'Obligatoire',
    available: 'Disponible',
    uninstall: 'Désinstaller',
    availableWithoutEnrollment: 'Disponible sans inscription',
  },
  filterMode: { include: 'inclure', exclude: 'exclure' },
  via: {
    direct: 'Groupe direct',
    allUsers: 'Tous les utilisateurs',
    allLicensedUsers: 'Tous les utilisateurs',
    allDevices: 'Tous les appareils',
  },
  phase: {
    idle: 'En attente',
    groups: 'Lecture des groupes',
    lists: 'Lecture des listes',
    assignments: 'Lecture des assignations',
    indexing: "Construction de l'index",
    saving: 'Enregistrement du cache',
    done: 'À jour',
    error: 'Échec de la synchronisation',
  },
  globalNote:
    "Assignations globales (indicatif) : ces règles visent « Tous les utilisateurs » ou « Tous les appareils ». " +
    "Elles s'appliquent potentiellement à ce groupe selon le type de ses membres, ce que la v1 ne calcule pas. " +
    'Les exclusions de ce groupe sur ces règles sont signalées.',
  errors: {
    network: { title: 'Serveur arrêté', text: "L'outil local ne répond plus. Relancez Start-IntuneAssignLens.ps1 puis rouvrez la page." },
    session: { title: 'Session invalide', text: "Le lien de session n'est plus valable (page rechargée ou outil relancé). Relancez Start-IntuneAssignLens.ps1 : il rouvre Edge avec un nouveau lien." },
    generic: 'Une erreur est survenue. Consultez le journal local.',
  },
};

// Libellés lisibles des types OData les plus courants ; repli : découpage du nom technique.
const TYPE_LABELS = {
  win32LobApp: 'Application Win32',
  winGetApp: 'Microsoft Store (nouveau)',
  officeSuiteApp: 'Microsoft 365 Apps',
  windowsMicrosoftEdgeApp: 'Microsoft Edge',
  win32CatalogApp: 'Application Win32 (catalogue)',
  windowsUniversalAppX: 'Application Windows (AppX / MSIX)',
  windowsMobileMSI: 'Application Windows (MSI)',
  windowsStoreApp: 'Microsoft Store (ancien)',
  windowsWebApp: 'Lien web Windows',
  microsoftStoreForBusinessApp: 'Microsoft Store Entreprise',
  iosVppApp: 'Application iOS (VPP)',
  iosStoreApp: 'Application iOS (Store)',
  androidManagedStoreApp: 'Android Enterprise (Play géré)',
  webApp: 'Lien web',
  macOSLobApp: 'Application macOS (LOB)',
  windows10GeneralConfiguration: 'Restrictions Windows',
  windows10EndpointProtectionConfiguration: 'Endpoint Protection Windows',
  windows10CustomConfiguration: 'Personnalisé (OMA-URI)',
  iosDeviceFeaturesConfiguration: 'Fonctionnalités iOS',
  androidWorkProfileGeneralDeviceConfiguration: 'Android profil professionnel',
  macOSCustomConfiguration: 'Personnalisé macOS',
  deviceManagementConfigurationPolicy: 'Catalogue de paramètres',
  groupPolicyConfiguration: 'Modèle ADMX',
  windows10CompliancePolicy: 'Conformité Windows',
  iosCompliancePolicy: 'Conformité iOS',
  androidWorkProfileCompliancePolicy: 'Conformité Android',
  macOSCompliancePolicy: 'Conformité macOS',
  deviceManagementScript: 'Script PowerShell',
  deviceHealthScript: 'Remédiation',
  deviceManagementIntent: 'Sécurité (intent)',
  windowsFeatureUpdateProfile: 'Mise à jour de fonctionnalités',
  windowsQualityUpdateProfile: 'Mise à jour qualité',
  windowsDriverUpdateProfile: 'Mise à jour de pilotes',
  iosManagedAppProtection: 'Protection d\'application iOS',
  androidManagedAppProtection: 'Protection d\'application Android',
  targetedManagedAppConfiguration: 'Configuration d\'application',
};

export function typeLabel(odataType) {
  const t = String(odataType || '').replace(/^#microsoft\.graph\./, '');
  if (!t) return '—';
  if (TYPE_LABELS[t]) return TYPE_LABELS[t];
  return t.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/^./, (c) => c.toUpperCase());
}

export function filterLabel(filter) {
  if (!filter) return '';
  const m = T.filterMode[filter.mode] || filter.mode || '';
  return m ? `${filter.name} (${m})` : filter.name;
}

export function intentLabel(intent) {
  return intent ? T.intent[intent] || intent : '';
}
