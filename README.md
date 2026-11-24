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

## Preço por lote
- No projeto Supabase do site, execute `supabase/lotes.sql` no SQL Editor depois de `supabase/valor-sobrio.sql` (ou `supabase/tudo.sql`).
- Em **Admin → Controle de Inscrições → Preço por lote**, adicione os lotes, o número final de inscritos de cada um e o preço. Exemplo: até 80 por R$ X; até 150 por R$ Y. O segundo lote começa na 81ª inscrição.
- Clique em **Salvar limite, datas e pagamento**. O preço exibido ao público é atualizado automaticamente a cada 30 segundos e o banco confirma o valor vigente no momento da inscrição. Ao atingir o fim do último lote, as inscrições encerram.
- Sem lotes configurados, continua valendo o preço único.
- Na área pública, o lote que já esgotou aparece **riscado** com a etiqueta "esgotado", o lote atual fica em destaque ("agora", com quantas vagas restam) e, na opção "Com cerveja", o preço do lote anterior aparece riscado ao lado do novo.

## Aviso público dos lotes e foto do kit
- Execute `supabase/mostrar-lotes.sql` no SQL Editor do mesmo projeto Supabase para exibir todas as faixas de preço na área de inscrições.
- No painel **Controle de Inscrições → Foto do kit da corrida**, envie uma imagem JPG, PNG ou WebP de até 5 MB. A foto aparece na área pública de inscrições.

## Data de nascimento e chave Pix
- Execute `supabase/nascimento-pix.sql` no SQL Editor (ou o `supabase/tudo.sql` inteiro).
- A data de nascimento é obrigatória na inscrição; quem não tem 18 anos até o dia da corrida (23/12/2026) não consegue se inscrever, no site e também no banco.
- Em **Controle de Inscrições → 4. Pagamento**, preencha **Chave Pix**: ela aparece em destaque no formulário com o botão **Copiar chave Pix**. O campo de instruções continua para o nome do recebedor e avisos.

