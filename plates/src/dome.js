import { Scene, Group, PerspectiveCamera, Vector3, MathUtils } from 'three';
import { CSS3DRenderer, CSS3DObject } from 'three/addons/renderers/CSS3DRenderer.js';
import './dome.css';

// Curved, staggered photo wall inspired by React Bits' Dome Gallery:
// https://reactbits.dev/components/dome-gallery
// Three.js handles the 3D transforms; the native buttons remain accessible.
const dome = document.getElementById('screen');
const stage = document.getElementById('stage');
const viewer = document.getElementById('viewer');
const photo = document.getElementById('viewerImage');
const status = document.getElementById('viewerStatus');
const count = document.getElementById('viewerCount');
const close = document.getElementById('close');
const previous = document.getElementById('previous');
const next = document.getElementById('next');
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const order = (window.PLATES || []).filter(Boolean).slice();

const scene = new Scene();
const sphere = new Group();
scene.add(sphere);
const camera = new PerspectiveCamera();
const renderer = new CSS3DRenderer();
stage.appendChild(renderer.domElement);
const columns = 32;
const rows = Math.max(1, Math.ceil(order.length / columns));
const latitudeStep = Math.min(10, 120 / rows);
const maxPitch = MathUtils.degToRad(Math.min(65, rows * latitudeStep / 2));
const tiles = [];
const rotation = { x: 0, y: 0, tx: 0, ty: 0 };
const velocity = { x: 0, y: 0 };
let radius = 600;
let frame = 0;
let lastTime = 0;
let drag = null;
let suppressClickUntil = 0;
let currentIndex = 0;
let origin = null;
let originRect = null;
let opening = false;
let closing = false;
let touchStart = null;
let adjacentPhotos = [];
const world = new Vector3();
const projected = new Vector3();
const normal = new Vector3();
const toCamera = new Vector3();
const clamp = MathUtils.clamp;

// Place the newest photos nearest the front, with the newest exactly centered.
// Viewer navigation retains date order independently of the spherical layout.
const slots = Array.from({ length: columns * rows }, (_, index) => {
  const col = Math.floor(index / rows);
  const row = index % rows;
  const longitude = col * Math.PI * 2 / columns;
  const latitude = MathUtils.degToRad((row - Math.floor(rows / 2) + (col % 2 ? .5 : 0)) * latitudeStep);
  return { longitude, latitude, depth: Math.cos(longitude) * Math.cos(latitude) };
}).sort((a, b) => b.depth - a.depth);

order.forEach((src, index) => {
  const { longitude, latitude } = slots[index];
  const element = document.createElement('div');
  element.className = 'dome-tile';
  const button = document.createElement('button');
  button.className = 'plate-card';
  button.type = 'button';
  button.dataset.index = index;
  button.dataset.src = src;
  button.setAttribute('aria-label', 'Open plate ' + (index + 1));
  element.appendChild(button);
  const object = new CSS3DObject(element);
  sphere.add(object);
  tiles.push({ object, button, longitude, latitude, loaded: false });
});

if (!order.length) {
  const empty = document.createElement('p');
  empty.className = 'empty';
  empty.textContent = 'No plates available.';
  dome.appendChild(empty);
}

function render() {
  sphere.rotation.set(rotation.x, rotation.y, 0, 'XYZ');
  scene.updateMatrixWorld(true);
  camera.updateMatrixWorld(true);
  for (const tile of tiles) {
    tile.object.getWorldPosition(world);
    normal.copy(world).normalize();
    toCamera.copy(camera.position).sub(world);
    projected.copy(world).project(camera);
    const nearView = normal.dot(toCamera) > 0 && Math.abs(projected.x) < 1.5 && Math.abs(projected.y) < 1.5;
    const inView = nearView && Math.abs(projected.x) < 1 && Math.abs(projected.y) < 1;
    tile.object.visible = nearView;
    tile.button.tabIndex = inView ? 0 : -1;
    tile.object.element.setAttribute('aria-hidden', String(!inView));
    if (nearView && !tile.loaded) {
      tile.button.style.backgroundImage = 'url(' + JSON.stringify(tile.button.dataset.src) + ')';
      tile.button.dataset.loaded = 'true';
      tile.loaded = true;
    }
  }
  renderer.render(scene, camera);
}

function resize() {
  const { width, height } = dome.getBoundingClientRect();
  radius = Math.max(600, Math.min(width * .7, height * 1.1));
  renderer.setSize(width, height);
  camera.fov = MathUtils.radToDeg(2 * Math.atan(height / (4 * radius)));
  camera.aspect = width / height;
  camera.near = 1;
  camera.far = radius * 6;
  camera.position.set(0, 0, radius * 2.2);
  camera.updateProjectionMatrix();
  for (const tile of tiles) {
    const { longitude: lon, latitude: lat, object } = tile;
    object.position.set(radius * Math.sin(lon) * Math.cos(lat), radius * Math.sin(lat), radius * Math.cos(lon) * Math.cos(lat));
    object.lookAt(object.position.clone().multiplyScalar(2));
    object.element.style.width = (2 * Math.PI * radius / columns * Math.cos(lat) * .96) + 'px';
    object.element.style.height = (radius * MathUtils.degToRad(latitudeStep) * .95) + 'px';
  }
  render();
}

function tick(now) {
  frame = 0;
  if (viewer.open || document.hidden) return;
  const dt = Math.min(32, now - (lastTime || now - 16.67));
  lastTime = now;
  if (!drag && !reducedMotion.matches) {
    rotation.tx = clamp(rotation.tx + velocity.x * dt, -maxPitch, maxPitch);
    rotation.ty += velocity.y * dt;
    const friction = Math.pow(.82, dt / 16.67);
    velocity.x *= friction;
    velocity.y *= friction;
  }
  const ease = reducedMotion.matches ? 1 : 1 - Math.exp(-dt / 95);
  rotation.x += (rotation.tx - rotation.x) * ease;
  rotation.y += (rotation.ty - rotation.y) * ease;
  render();
  if (Math.abs(rotation.tx - rotation.x) + Math.abs(rotation.ty - rotation.y) > .00005 ||
      Math.abs(velocity.x) + Math.abs(velocity.y) > .000002) {
    frame = requestAnimationFrame(tick);
  } else {
    rotation.x = rotation.tx;
    rotation.y = rotation.ty;
    velocity.x = velocity.y = 0;
    render();
  }
}
function wake() {
  if (!frame && !viewer.open && !document.hidden) {
    lastTime = performance.now();
    frame = requestAnimationFrame(tick);
  }
}
function stopMotion() {
  cancelAnimationFrame(frame);
  frame = 0;
  velocity.x = velocity.y = 0;
  rotation.tx = rotation.x;
  rotation.ty = rotation.y;
}

dome.addEventListener('pointerdown', event => {
  if (viewer.open || event.button !== 0 || !event.isPrimary) return;
  stopMotion();
  drag = { id: event.pointerId, x: event.clientX, y: event.clientY, lastX: event.clientX, lastY: event.clientY, time: performance.now(), moved: false };
});
dome.addEventListener('pointermove', event => {
  if (!drag || drag.id !== event.pointerId) return;
  const now = performance.now();
  const dx = event.clientX - drag.lastX;
  const dy = event.clientY - drag.lastY;
  if (!drag.moved && Math.hypot(event.clientX - drag.x, event.clientY - drag.y) > 6) {
    drag.moved = true;
    dome.setPointerCapture(event.pointerId);
    dome.classList.add('is-dragging');
  }
  if (drag.moved) {
    const speed = .00085;
    rotation.tx = clamp(rotation.tx + dy * speed, -maxPitch, maxPitch);
    rotation.ty += dx * speed;
    const dt = Math.max(8, now - drag.time);
    velocity.x = clamp(dy * speed / dt, -.001, .001);
    velocity.y = clamp(dx * speed / dt, -.001, .001);
    wake();
  }
  drag.lastX = event.clientX;
  drag.lastY = event.clientY;
  drag.time = now;
});
function endDrag(event) {
  if (!drag || (event.pointerId !== undefined && event.pointerId !== drag.id)) return;
  if (drag.moved) suppressClickUntil = performance.now() + 220;
  if (performance.now() - drag.time > 80 || event.type === 'pointercancel' || reducedMotion.matches) velocity.x = velocity.y = 0;
  if (dome.hasPointerCapture(drag.id)) dome.releasePointerCapture(drag.id);
  drag = null;
  dome.classList.remove('is-dragging');
  wake();
}
dome.addEventListener('pointerup', endDrag);
dome.addEventListener('pointercancel', endDrag);
dome.addEventListener('lostpointercapture', endDrag);
window.addEventListener('pointerup', endDrag);
dome.addEventListener('wheel', event => {
  if (viewer.open || event.ctrlKey) return;
  event.preventDefault();
  velocity.x = velocity.y = 0;
  const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? innerHeight : 1;
  if (event.shiftKey || Math.abs(event.deltaX) > Math.abs(event.deltaY)) {
    rotation.ty += clamp((event.shiftKey ? event.deltaY : event.deltaX) * unit, -120, 120) * .001;
  } else {
    rotation.tx = clamp(rotation.tx + clamp(event.deltaY * unit, -120, 120) * .001, -maxPitch, maxPitch);
  }
  wake();
}, { passive: false });

function animatePhoto(from, to, reverse = false) {
  if (reducedMotion.matches || !from || !to.width || !to.height) return null;
  const transform = 'translate(' + (from.left + from.width / 2 - to.left - to.width / 2) + 'px,' +
    (from.top + from.height / 2 - to.top - to.height / 2) + 'px) scale(' + from.width / to.width + ',' + from.height / to.height + ')';
  const frames = [{ transform, opacity: .35 }, { transform: 'none', opacity: 1 }];
  return photo.animate(reverse ? frames.reverse() : frames, { duration: reverse ? 280 : 420, easing: 'cubic-bezier(.2,.7,.2,1)' });
}
photo.addEventListener('load', () => {
  viewer.classList.remove('is-loading', 'has-error');
  status.textContent = '';
  if (opening && viewer.open) animatePhoto(originRect, photo.getBoundingClientRect());
  opening = false;
});
photo.addEventListener('error', () => {
  viewer.classList.remove('is-loading');
  viewer.classList.add('has-error');
  status.textContent = 'This photo could not load. Try the next plate.';
  opening = false;
});
function displayPlate(index) {
  if (closing || !order.length) return;
  photo.getAnimations().forEach(animation => animation.cancel());
  currentIndex = (index + order.length) % order.length;
  viewer.classList.remove('has-error');
  viewer.classList.add('is-loading');
  status.textContent = 'Loading photo...';
  photo.alt = 'Michigan vanity license plate ' + (currentIndex + 1);
  photo.src = order[currentIndex];
  count.textContent = (currentIndex + 1) + ' / ' + order.length;
  previous.disabled = next.disabled = order.length < 2;
  adjacentPhotos = [-1, 1].map(offset => {
    const image = new Image();
    image.src = order[(currentIndex + offset + order.length) % order.length];
    return image;
  });
}
function openPlate(button) {
  if (!button || viewer.open || performance.now() < suppressClickUntil) return;
  stopMotion();
  origin = button;
  originRect = button.getBoundingClientRect();
  opening = true;
  displayPlate(Number(button.dataset.index));
  viewer.showModal();
  dome.classList.add('is-viewing');
  dome.inert = true;
  close.focus({ preventScroll: true });
}
dome.addEventListener('click', event => openPlate(event.target.closest('.plate-card')));
async function closePlate() {
  if (closing || !viewer.open) return;
  closing = true;
  photo.getAnimations().forEach(animation => animation.cancel());
  if (origin && Number(origin.dataset.index) === currentIndex && !viewer.classList.contains('is-loading')) {
    const animation = animatePhoto(origin.getBoundingClientRect(), photo.getBoundingClientRect(), true);
    if (animation) await animation.finished.catch(() => {});
  }
  viewer.close();
  dome.inert = false;
  dome.classList.remove('is-viewing');
  opening = closing = false;
  touchStart = null;
  if (origin) origin.focus({ preventScroll: true });
}
close.addEventListener('click', closePlate);
viewer.addEventListener('cancel', event => { event.preventDefault(); closePlate(); });
viewer.addEventListener('click', event => { if (event.target === viewer) closePlate(); });
previous.addEventListener('click', () => { opening = false; displayPlate(currentIndex - 1); });
next.addEventListener('click', () => { opening = false; displayPlate(currentIndex + 1); });
document.addEventListener('keydown', event => {
  if (event.altKey || event.ctrlKey || event.metaKey) return;
  if (viewer.open) {
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault();
      opening = false;
      displayPlate(currentIndex + (event.key === 'ArrowRight' ? 1 : -1));
    } else if (event.key.toLowerCase() === 'x') {
      event.preventDefault();
      closePlate();
    }
  } else if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) {
    event.preventDefault();
    dome.focus({ preventScroll: true });
    velocity.x = velocity.y = 0;
    if (event.key === 'ArrowLeft') rotation.ty -= .15;
    if (event.key === 'ArrowRight') rotation.ty += .15;
    if (event.key === 'ArrowUp') rotation.tx = clamp(rotation.tx - .12, -maxPitch, maxPitch);
    if (event.key === 'ArrowDown') rotation.tx = clamp(rotation.tx + .12, -maxPitch, maxPitch);
    wake();
  }
});
photo.addEventListener('touchstart', event => {
  touchStart = event.touches.length === 1 ? { x: event.touches[0].clientX, y: event.touches[0].clientY } : null;
}, { passive: true });
photo.addEventListener('touchend', event => {
  if (!touchStart || event.touches.length) return;
  const dx = event.changedTouches[0].clientX - touchStart.x;
  const dy = event.changedTouches[0].clientY - touchStart.y;
  touchStart = null;
  if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.5) {
    opening = false;
    displayPlate(currentIndex + (dx < 0 ? 1 : -1));
  }
}, { passive: true });
photo.addEventListener('touchcancel', () => { touchStart = null; });
window.addEventListener('blur', () => { endDrag({ type: 'pointercancel' }); stopMotion(); });
document.addEventListener('visibilitychange', () => { if (document.hidden) stopMotion(); });
reducedMotion.addEventListener('change', stopMotion);
new ResizeObserver(resize).observe(dome);
resize();
