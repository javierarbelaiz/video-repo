'use strict';

// Un equirectangular y un video plano son ambos mp4: nada en el archivo los
// distingue de forma confiable. El sufijo _360 en el nombre es la marca.
function is360(name) {
  return /_360\.[^.]+$/i.test(name);
}

function filter360(videos) {
  return videos.filter(function (v) { return is360(v.name); });
}

window.VR360 = { is360: is360, filter360: filter360 };

var msgEl = document.getElementById('msg');
var listEl = document.getElementById('list');
var stageEl = document.getElementById('stage');
var videoEl = document.getElementById('video');

function human(b) {
  var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
  while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
  return b.toFixed(1) + ' ' + u[i];
}

function show(kind, html) {
  msgEl.className = kind;
  msgEl.innerHTML = html;
}

function clearMsg() {
  msgEl.className = '';
  msgEl.innerHTML = '';
}

function render(videos) {
  var only360 = filter360(videos);
  listEl.innerHTML = '';

  if (only360.length === 0) {
    show('info',
      'No hay videos 360 todavia. Se listan solo los archivos cuyo nombre termina en ' +
      '<code>_360</code> antes de la extension, por ejemplo <code>playa_360.mp4</code>. ' +
      'Subilos desde <a href="/" style="color:#2f81f7">la pagina principal</a> y renombralos con ese sufijo.');
    return;
  }

  clearMsg();
  only360.forEach(function (v) {
    var li = document.createElement('li');
    var b = document.createElement('button');
    b.className = 'pick';
    b.innerHTML = '<span>🌐 ' + v.name.replace(/[<>&]/g, '') + '</span>' +
                  '<span class="s">' + human(v.size) + '</span>';
    b.onclick = function () { select(v); };
    li.appendChild(b);
    listEl.appendChild(li);
  });
}

function select(v) {
  videoEl.src = '/videos/' + encodeURIComponent(v.name);
  listEl.style.display = 'none';
  stageEl.className = 'on';
}

function backToList() {
  videoEl.pause();
  videoEl.removeAttribute('src');
  videoEl.load();
  stageEl.className = '';
  listEl.style.display = '';
}

function load() {
  fetch('/api/videos')
    .then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    })
    .then(render)
    .catch(function (e) {
      show('err', 'No se pudo leer la lista de videos: ' + e.message +
        ' <button class="btn sec" onclick="location.reload()">Reintentar</button>');
    });
}

videoEl.addEventListener('error', function () {
  var err = videoEl.error;
  var names = { 1: 'ABORTED', 2: 'NETWORK', 3: 'DECODE', 4: 'SRC_NOT_SUPPORTED' };
  show('err', 'Fallo el video: ' + (err ? (names[err.code] || err.code) : 'desconocido') +
    '. Con material 4K un fallo de decodificacion es plausible.');
});

document.getElementById('back').onclick = backToList;

load();
