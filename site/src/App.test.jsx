import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { App } from './App';

function response(status, payload) {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(payload),
  });
}

describe('site zspeak', () => {
  beforeEach(() => {
    vi.stubGlobal('fetch', vi.fn(() => response(401, { error: 'Autenticação necessária' })));
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('apresenta o produto local e diferencia macOS de Windows em desenvolvimento', async () => {
    render(<App />);
    expect(screen.getByRole('heading', { name: 'Fale. O texto aparece.' })).toBeInTheDocument();
    expect(screen.getByText('Só a conta é online')).toBeInTheDocument();
    expect(screen.getByText('Em desenvolvimento')).toBeInTheDocument();
    expect(screen.getByAltText('Janela do zspeak exibindo uma transcrição ao vivo')).toBeInTheDocument();
    await waitFor(() => expect(fetch).toHaveBeenCalledWith('/api/auth/me', expect.any(Object)));
  });

  it('exige conta antes de abrir a área de download', async () => {
    const user = userEvent.setup();
    render(<App />);
    await user.click(screen.getByRole('button', { name: 'Criar conta e começar' }));
    expect(screen.getByRole('dialog', { name: 'Crie sua conta.' })).toBeInTheDocument();
    expect(screen.getByLabelText('Seu nome')).toBeRequired();
    expect(screen.getByLabelText('E-mail')).toBeRequired();
    expect(screen.getByLabelText('Senha')).toHaveAttribute('minlength', '12');
  });

  it('cadastra, autentica e consulta downloads protegidos', async () => {
    fetch.mockImplementation((url, options = {}) => {
      if (url === '/api/auth/me') return response(401, { error: 'Autenticação necessária' });
      if (url === '/api/auth/register' && options.method === 'POST') {
        return response(200, { user: { id: 'u1', name: 'Michel Zandonai', email: 'michel@example.com' } });
      }
      if (url === '/api/downloads') {
        return response(200, {
          platforms: [
            { id: 'macos', name: 'macOS', statusLabel: 'Publicação pendente', url: null },
            { id: 'windows', name: 'Windows 11', statusLabel: 'Em desenvolvimento', url: null },
          ],
        });
      }
      return response(404, { error: 'Não encontrado' });
    });

    const user = userEvent.setup();
    render(<App />);
    await user.click(screen.getByRole('button', { name: 'Criar conta e começar' }));
    await user.type(screen.getByLabelText('Seu nome'), 'Michel Zandonai');
    await user.type(screen.getByLabelText('E-mail'), 'michel@example.com');
    await user.type(screen.getByLabelText('Senha'), 'SenhaLocal123');
    const registerDialog = screen.getByRole('dialog', { name: 'Crie sua conta.' });
    await user.click(within(registerDialog).getByRole('button', { name: 'Criar conta' }));

    const downloadDialog = await screen.findByRole('dialog', { name: 'Escolha seu sistema.' });
    expect(within(downloadDialog).getByText('Windows 11')).toBeInTheDocument();
    expect(fetch).toHaveBeenCalledWith('/api/auth/register', expect.objectContaining({ method: 'POST' }));
    expect(fetch).toHaveBeenCalledWith('/api/downloads', expect.objectContaining({ credentials: 'include' }));
  });

  it('mostra erro de credenciais sem fechar o login', async () => {
    fetch.mockImplementation((url) => {
      if (url === '/api/auth/login') return response(401, { error: 'E-mail ou senha inválidos' });
      return response(401, { error: 'Autenticação necessária' });
    });

    const user = userEvent.setup();
    render(<App />);
    await user.click(screen.getByRole('button', { name: 'Entrar' }));
    const loginDialog = screen.getByRole('dialog', { name: 'Que bom ter você de volta.' });
    await user.type(screen.getByLabelText('E-mail'), 'michel@example.com');
    await user.type(screen.getByLabelText('Senha'), 'senha-incorreta');
    await user.click(within(loginDialog).getByRole('button', { name: 'Entrar' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('E-mail ou senha inválidos');
    expect(screen.getByRole('dialog', { name: 'Que bom ter você de volta.' })).toBeInTheDocument();
  });
});
