const toggle = document.querySelector('.nav-toggle');
const menu = document.querySelector('.nav-links');

toggle?.addEventListener('click', () => {
  const isOpen = toggle.getAttribute('aria-expanded') === 'true';
  toggle.setAttribute('aria-expanded', String(!isOpen));
  menu?.classList.toggle('open', !isOpen);
});

menu?.querySelectorAll('a').forEach((link) => {
  link.addEventListener('click', () => {
    toggle?.setAttribute('aria-expanded', 'false');
    menu.classList.remove('open');
  });
});

const year = document.querySelector('#year');
if (year) year.textContent = String(new Date().getFullYear());
