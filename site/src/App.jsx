import { useEffect, useId, useState } from 'react';
import { version as siteVersion } from '../package.json';
import {
  ArrowRight,
  Check,
  CaretLeft,
  CaretRight,
  Download,
  GithubLogo,
  List,
  LockKey,
  Microphone,
  Monitor,
  SignOut,
  Sparkle,
  Waveform,
  X,
} from '@phosphor-icons/react';

const API_URL = import.meta.env.VITE_API_URL || '/api';

const productShots = [
  {
    src: '/assets/app/macos-overlay-recording.png',
    title: 'Transcrição ao vivo',
    text: 'Acompanhe o texto enquanto fala, sem sair do app em que está trabalhando.',
  },
  {
    src: '/assets/app/macos-settings-overview.png',
    title: 'Tudo sob seu controle',
    text: 'Atalho, permissões, modelo e histórico organizados em uma visão simples.',
  },
  {
    src: '/assets/app/macos-audio-meeting.png',
    title: 'Arquivos e reuniões',
    text: 'Transcreva áudios longos, identifique falantes e copie o resultado localmente.',
  },
];

const localItems = ['Áudio', 'Texto', 'Histórico', 'Vocabulário', 'Modelos de IA'];

async function api(path, options = {}) {
  const response = await fetch(`${API_URL}${path}`, {
    credentials: 'include',
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.message || payload.error || 'Não foi possível concluir agora.');
  return payload;
}

function Brand() {
  return (
    <a className="brand" href="#inicio" aria-label="zspeak, início">
      <img src="/assets/zspeak-icon.png" alt="" />
      <span>zspeak</span>
    </a>
  );
}

function AuthDialog({ initialMode, onClose, onAuthenticated }) {
  const [mode, setMode] = useState(initialMode);
  const [status, setStatus] = useState({ loading: false, error: '' });
  const titleId = useId();

  async function handleSubmit(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const body = Object.fromEntries(form.entries());
    setStatus({ loading: true, error: '' });
    try {
      const data = await api(mode === 'register' ? '/auth/register' : '/auth/login', {
        method: 'POST',
        body: JSON.stringify(body),
      });
      onAuthenticated(data.user);
    } catch (error) {
      setStatus({ loading: false, error: error.message });
    }
  }

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="auth-dialog" role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <button className="icon-button close-button" type="button" onClick={onClose} aria-label="Fechar">
          <X size={20} />
        </button>
        <div className="auth-mark"><LockKey size={24} weight="fill" /></div>
        <p className="kicker">Sua entrada no zspeak</p>
        <h2 id={titleId}>{mode === 'register' ? 'Crie sua conta.' : 'Que bom ter você de volta.'}</h2>
        <p className="auth-intro">A conta libera o acesso. Áudio, transcrições, histórico e vocabulário continuam apenas no seu computador.</p>
        <form onSubmit={handleSubmit}>
          {mode === 'register' && (
            <label>
              Seu nome
              <input name="name" autoComplete="name" minLength="2" maxLength="80" required placeholder="Como podemos chamar você?" />
            </label>
          )}
          <label>
            E-mail
            <input name="email" type="email" autoComplete="email" required placeholder="voce@exemplo.com" />
          </label>
          <label>
            Senha
            <input
              name="password"
              type="password"
              autoComplete={mode === 'register' ? 'new-password' : 'current-password'}
              minLength={mode === 'register' ? 12 : 1}
              maxLength="128"
              pattern={mode === 'register' ? '(?=.*[a-z])(?=.*[A-Z])(?=.*[0-9]).{12,128}' : undefined}
              required
              placeholder={mode === 'register' ? '12+ caracteres, com maiúscula e número' : 'Sua senha'}
            />
          </label>
          {status.error && <p className="form-error" role="alert">{status.error}</p>}
          <button className="button primary full" type="submit" disabled={status.loading}>
            {status.loading ? 'Só um instante…' : mode === 'register' ? 'Criar conta' : 'Entrar'}
            {!status.loading && <ArrowRight size={18} weight="bold" />}
          </button>
        </form>
        <p className="auth-switch">
          {mode === 'register' ? 'Já tem uma conta?' : 'Ainda não tem conta?'}{' '}
          <button type="button" onClick={() => { setMode(mode === 'register' ? 'login' : 'register'); setStatus({ loading: false, error: '' }); }}>
            {mode === 'register' ? 'Entrar' : 'Criar agora'}
          </button>
        </p>
      </section>
    </div>
  );
}

function DownloadDialog({ onClose }) {
  const [releases, setReleases] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    api('/downloads').then(setReleases).catch((requestError) => setError(requestError.message));
  }, []);

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="download-dialog" role="dialog" aria-modal="true" aria-labelledby="download-title">
        <button className="icon-button close-button" type="button" onClick={onClose} aria-label="Fechar"><X size={20} /></button>
        <p className="kicker">Acesso liberado</p>
        <h2 id="download-title">Escolha seu sistema.</h2>
        <p>Baixe o instalador do seu sistema quando ele estiver disponível.</p>
        {error && <p className="form-error" role="alert">{error}</p>}
        {!releases && !error && <p className="loading-copy">Carregando opções…</p>}
        {releases && (
          <div className="download-options">
            {releases.platforms.map((platform) => (
              <article key={platform.id}>
                <span className="platform-symbol"><Monitor size={24} /></span>
                <div><strong>{platform.name}</strong><small>{platform.statusLabel}</small></div>
                {platform.url ? (
                  <a className="icon-button" href={platform.url} aria-label={`Baixar ${platform.name}`}><Download size={20} /></a>
                ) : <span className="soon">Em breve</span>}
              </article>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

export function App() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [authMode, setAuthMode] = useState(null);
  const [downloadOpen, setDownloadOpen] = useState(false);
  const [user, setUser] = useState(null);
  const [activeShot, setActiveShot] = useState(0);

  useEffect(() => {
    api('/auth/me').then((data) => setUser(data.user)).catch(() => setUser(null));
  }, []);

  function requestAccess(mode = 'register') {
    if (user) setDownloadOpen(true);
    else setAuthMode(mode);
  }

  async function logout() {
    try { await api('/auth/logout', { method: 'POST' }); } finally { setUser(null); }
  }

  function nextShot(direction) {
    setActiveShot((current) => (current + direction + productShots.length) % productShots.length);
  }

  return (
    <>
      <a className="skip-link" href="#conteudo">Ir para o conteúdo</a>
      <header className="site-header">
        <nav className="nav shell" aria-label="Navegação principal">
          <Brand />
          <button className="menu-button" type="button" aria-expanded={menuOpen} aria-controls="nav-links" onClick={() => setMenuOpen(!menuOpen)}>
            {menuOpen ? <X size={24} /> : <List size={24} />}
            <span className="sr-only">{menuOpen ? 'Fechar menu' : 'Abrir menu'}</span>
          </button>
          <div className={`nav-links ${menuOpen ? 'open' : ''}`} id="nav-links">
            <a href="#produto" onClick={() => setMenuOpen(false)}>Produto</a>
            <a href="#plataformas" onClick={() => setMenuOpen(false)}>Plataformas</a>
            <a href="#privacidade" onClick={() => setMenuOpen(false)}>Privacidade</a>
            {user ? (
              <>
                <button className="nav-access" type="button" onClick={() => requestAccess()}>Download</button>
                <button className="user-button" type="button" onClick={logout} title="Sair">
                  <span>{user.name?.split(' ')[0]}</span><SignOut size={18} />
                </button>
              </>
            ) : (
              <button className="nav-access" type="button" onClick={() => setAuthMode('login')}>Entrar</button>
            )}
          </div>
        </nav>
      </header>

      <main id="conteudo">
        <section className="hero shell" id="inicio">
          <div className="hero-copy">
            <p className="eyebrow"><span /> macOS + Windows</p>
            <h1>Fale. O texto aparece.</h1>
            <p className="hero-lead">Transcrição por voz feita no seu computador. Use no editor, no navegador ou em qualquer app — sem enviar sua voz para a nuvem.</p>
            <div className="hero-actions">
              <button className="button primary" type="button" onClick={() => requestAccess('register')}>
                {user ? 'Acessar downloads' : 'Criar conta e começar'} <ArrowRight size={19} weight="bold" />
              </button>
              <a className="button ghost" href="#produto">Conhecer o app</a>
            </div>
            <ul className="trust-list" aria-label="Diferenciais">
              <li><Check size={16} weight="bold" /> Processamento local</li>
              <li><Check size={16} weight="bold" /> Funciona offline</li>
              <li><Check size={16} weight="bold" /> Só a conta é online</li>
            </ul>
          </div>
          <div className="hero-product" aria-label="zspeak transcrevendo ao vivo no macOS">
            <div className="hero-product-top">
              <span><i /> AO VIVO</span>
              <span className="local-chip"><LockKey size={14} weight="fill" /> LOCAL</span>
            </div>
            <img src="/assets/app/macos-tray-recording.png" alt="Janela do zspeak exibindo uma transcrição ao vivo" />
            <div className="hero-product-caption">
              <Waveform size={21} weight="bold" />
              <div><strong>Continue no seu fluxo</strong><small>Atalho global · texto no app ativo</small></div>
            </div>
          </div>
        </section>

        <section className="flow-strip" aria-label="Fluxo local">
          <div className="shell flow-row">
            <span><Microphone size={18} /> Sua voz</span><ArrowRight size={16} /><span><Waveform size={18} /> Parakeet V3</span><ArrowRight size={16} /><span><Sparkle size={18} /> Texto pronto</span><ArrowRight size={16} /><span><Monitor size={18} /> Seu app</span>
          </div>
        </section>

        <section className="section product shell" id="produto">
          <div className="section-heading">
            <p className="eyebrow"><span /> O app de verdade</p>
            <h2>Menos interface.<br />Mais continuidade.</h2>
            <p>O zspeak fica discreto até você chamar. Grave por atalho, acompanhe a transcrição e siga trabalhando.</p>
          </div>
          <div className="showcase">
            <div className="showcase-stage">
              <img src={productShots[activeShot].src} alt={`${productShots[activeShot].title} no zspeak para macOS`} />
            </div>
            <div className="showcase-footer">
              <div><span>{String(activeShot + 1).padStart(2, '0')} / 03</span><h3>{productShots[activeShot].title}</h3><p>{productShots[activeShot].text}</p></div>
              <div className="showcase-controls">
                <button className="icon-button" type="button" onClick={() => nextShot(-1)} aria-label="Captura anterior"><CaretLeft size={21} /></button>
                <button className="icon-button" type="button" onClick={() => nextShot(1)} aria-label="Próxima captura"><CaretRight size={21} /></button>
              </div>
            </div>
          </div>
        </section>

        <section className="section platforms-wrap" id="plataformas">
          <div className="shell">
            <div className="section-heading split-heading">
              <div><p className="eyebrow"><span /> Nativo em cada sistema</p><h2>O mesmo zspeak.<br />Dois caminhos.</h2></div>
              <p>Sem uma camada web fingindo ser desktop. Cada versão usa as APIs do próprio sistema para áudio, atalho e inserção de texto.</p>
            </div>
            <div className="platform-grid">
              <article className="platform-card">
                <div className="platform-card-top"><span className="os-badge">macOS</span><span className="status ready"><i /> Em validação</span></div>
                <h3>Feito para Apple Silicon.</h3>
                <p>SwiftUI, CoreML e Apple Neural Engine para transcrição rápida, silenciosa e local.</p>
                <ul><li><Check size={16} /> Overlay e menu bar</li><li><Check size={16} /> Atalho configurável</li><li><Check size={16} /> Arquivos e reuniões</li><li><Check size={16} /> LLM local opcional</li></ul>
              </article>
              <article className="platform-card dark-card">
                <div className="platform-card-top"><span className="os-badge">Windows 11</span><span className="status building"><i /> Em desenvolvimento</span></div>
                <h3>Nativo, sem atalhos.</h3>
                <p>C#/.NET 8, WPF, WASAPI e ONNX Runtime em uma implementação independente.</p>
                <ul><li><Check size={16} /> Tray e overlay</li><li><Check size={16} /> Hotkey global</li><li><Check size={16} /> Inserção no app ativo</li><li><Check size={16} /> Instalador por usuário</li></ul>
              </article>
            </div>
          </div>
        </section>

        <section className="section privacy shell" id="privacidade">
          <div className="privacy-copy">
            <p className="eyebrow"><span /> Local por arquitetura</p>
            <h2>O login sabe quem você é.<br />Não sabe o que você disse.</h2>
            <p>A conta é a única etapa online obrigatória. Depois disso, o conteúdo de uso permanece no seu dispositivo.</p>
            <button className="text-button" type="button" onClick={() => requestAccess('register')}>Criar minha conta <ArrowRight size={17} weight="bold" /></button>
          </div>
          <div className="privacy-panel">
            <span className="privacy-panel-label">Fica no computador</span>
            {localItems.map((item, index) => <div key={item}><span>{String(index + 1).padStart(2, '0')}</span><strong>{item}</strong><LockKey size={19} /></div>)}
            <small>Sem upload de áudio. Sem sincronização de transcrições. Sem telemetria de conteúdo.</small>
          </div>
        </section>

        <section className="cta shell">
          <img src="/assets/zspeak-icon.png" alt="" />
          <div><p className="eyebrow"><span /> Sua voz, no seu fluxo</p><h2>Comece com uma conta.<br />Continue localmente.</h2></div>
          <button className="button light" type="button" onClick={() => requestAccess('register')}>{user ? 'Acessar downloads' : 'Criar conta'} <ArrowRight size={19} weight="bold" /></button>
        </section>
      </main>

      <footer>
        <div className="shell footer-row">
          <Brand />
          <p>Transcrição local para macOS e Windows.</p>
          <a href="https://github.com/michelzandonai/zspeak" target="_blank" rel="noreferrer">GitHub <GithubLogo size={18} /></a>
          <p>v{siteVersion} · {new Date().getFullYear()}</p>
        </div>
      </footer>

      {authMode && <AuthDialog initialMode={authMode} onClose={() => setAuthMode(null)} onAuthenticated={(authenticatedUser) => { setUser(authenticatedUser); setAuthMode(null); setDownloadOpen(true); }} />}
      {downloadOpen && <DownloadDialog onClose={() => setDownloadOpen(false)} />}
    </>
  );
}
