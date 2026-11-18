// link.js : liens de partage d'une fiche (logique pure, testée par node --test).
//
// Le port et le jeton de session changent à chaque lancement : l'adresse locale (127.0.0.1:port) ne peut donc
// pas être partagée. Le lien partagé ne contient que le type et l'identifiant Microsoft (identiques pour
// tous les utilisateurs du même tenant). Le collègue le colle (Ctrl+V) dans son propre Intune Lens.

export const LINK_PREFIX = 'intune-lens://';
const KINDS = ['user', 'device', 'group', 'object'];

/** Lien de partage d'une fiche. */
export function shareLink(kind, id) {
  if (!KINDS.includes(kind) || !id) return '';
  return `${LINK_PREFIX}${kind}/${encodeURIComponent(id)}`;
}

/**
 * Retrouve une fiche dans un texte collé : lien intune-lens://<type>/<id> (même au milieu d'un message),
 * ou adresse de l'outil contenant #/<type>/<id>. Renvoie { kind, id } ou null.
 */
export function parseShareLink(text) {
  const s = String(text ?? '').trim();
  if (!s || s.length > 2000) return null;
  const m = /intune-lens:\/\/(user|device|group|object)\/([^\s/?#<>"']+)/i.exec(s)
    || /^https?:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?\/[^#\s]*#\/(user|device|group|object)\/([^\s/?#<>"']+)/i.exec(s);
  if (!m) return null;
  let id;
  try { id = decodeURIComponent(m[2]); } catch { return null; }
  return id ? { kind: m[1].toLowerCase(), id } : null;
}
