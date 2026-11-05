# 4ª Corrida do Papai Noel — 2026

Site pronto (já compilado). Não precisa de build: basta publicar a pasta raiz.
Todos os caminhos são relativos, então funciona tanto no GitHub Pages quanto no Netlify.

## Publicar no GitHub Pages
1. No GitHub, abra o repositório → **Settings** → **Pages**.
2. Em **Source**, escolha **Deploy from a branch**.
3. Selecione a branch do site e a pasta **/ (root)** → **Save**.
4. Em 1–2 minutos o site fica em `https://lcapelete-ux.github.io/corridadopapainoel/`.

## Publicar no Netlify
1. **Add new site → Import an existing project** → escolha este repositório.
2. Deixe o build command vazio; o `netlify.toml` já define a pasta publicada (`.`).
3. Ou arraste a pasta do projeto em **app.netlify.com/drop**.

## Inscrições (abrir/encerrar)
- Rodar `supabase/setup.sql`, `supabase/admin.sql` e `supabase/inscricoes.sql` no SQL Editor do Supabase (nessa ordem, uma vez).
- No painel (Acesso Restrito Admin → aba **Controle de Inscrições**): abrir/encerrar na hora, limite de inscritos e data/hora de abertura e encerramento.
- A regra também é aplicada no banco (trigger), então ninguém consegue se inscrever fora do período ou acima do limite.
