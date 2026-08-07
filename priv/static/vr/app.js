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
  if (xrSession) { xrSession.end(); }
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

// ---------- reproductor WebXR ----------

var SPHERE_RADIUS = 500;

var renderer = null, scene = null, camera = null, xrSession = null;
var enterBtn = document.getElementById('enter');

function buildScene() {
  if (renderer) return;

  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(70, window.innerWidth / window.innerHeight, 0.1, 1100);

  // Esfera vista DESDE ADENTRO: escalar en -1 invierte las normales.
  var geo = new THREE.SphereGeometry(SPHERE_RADIUS, 60, 40);
  geo.scale(-1, 1, 1);

  var texture = new THREE.VideoTexture(videoEl);
  texture.colorSpace = THREE.SRGBColorSpace;

  scene.add(new THREE.Mesh(geo, new THREE.MeshBasicMaterial({ map: texture })));

  renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(window.devicePixelRatio);
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.xr.enabled = true;
  renderer.xr.setReferenceSpaceType('local');
  renderer.domElement.style.display = 'none';
  document.body.appendChild(renderer.domElement);
  renderer.setAnimationLoop(function () { renderer.render(scene, camera); });

  // Gatillo = play/pausa. El boton del sistema del Quest cierra la sesion solo.
  var controller = renderer.xr.getController(0);
  controller.addEventListener('selectstart', togglePlay);
  scene.add(controller);
}

function togglePlay() {
  if (videoEl.paused) { videoEl.play(); } else { videoEl.pause(); }
}

function onSessionEnd() {
  xrSession = null;
  renderer.domElement.style.display = 'none';
  videoEl.pause();
  enterBtn.disabled = false;
  enterBtn.textContent = 'Entrar en VR';
}

function enterVR() {
  // navigator.xr solo existe en contexto seguro. Es de lejos el fallo mas
  // probable de todo esto, asi que el mensaje tiene que ser explicito.
  if (!navigator.xr) {
    show('err', 'No hay WebXR en este navegador. La causa habitual es haber entrado por ' +
      '<code>http://</code>: WebXR solo funciona sobre <code>https://</code>. ' +
      'Proba con <code>https://192.168.1.199:30443/vr</code>.');
    return;
  }

  navigator.xr.isSessionSupported('immersive-vr').then(function (supported) {
    if (!supported) {
      show('info', 'Este dispositivo no soporta VR inmersiva. Podes ver el video plano aca abajo, ' +
        'pero para el 360 real hace falta el visor.');
      videoEl.controls = true;
      return;
    }

    buildScene();
    enterBtn.disabled = true;

    return navigator.xr.requestSession('immersive-vr', { optionalFeatures: ['local-floor'] })
      .then(function (session) {
        xrSession = session;
        session.addEventListener('end', onSessionEnd);
        renderer.domElement.style.display = '';
        return renderer.xr.setSession(session);
      })
      .then(function () {
        return videoEl.play();
      });
  }).catch(function (e) {
    enterBtn.disabled = false;
    show('err', 'No se pudo iniciar la sesion VR: ' + e.message);
  });
}

enterBtn.onclick = enterVR;

window.addEventListener('resize', function () {
  if (!renderer) return;
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

load();
