// theme-init.js : applique le thème enregistré AVANT le premier affichage de la page.
// Chargé comme script classique et bloquant dans <head> (les modules ES s'exécutent trop tard,
// ce qui provoquait un flash sombre -> clair). Clair par défaut ; aucune dépendance au thème Windows.
(function () {
  var theme = 'light';
  try {
    var s = JSON.parse(localStorage.getItem('ial.settings.v2') || '{}');
    if (s && s.theme === 'dark') theme = 'dark';
  } catch (e) { /* stockage indisponible : clair */ }
  document.documentElement.setAttribute('data-theme', theme);
})();
