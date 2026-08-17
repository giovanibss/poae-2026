# POAE · Sala ao Vivo

Protótipo funcional do módulo de sala de aula ao vivo do curso de Poder
Aeroespacial. Nuvem de palavras com moderação, em três superfícies.

Modo diagnóstico: sem nota, sem proctoring, identidade por apelido livre
sobre autenticação anônima do Supabase.

## Estrutura

```
index.html                        aplicação inteira (aluno, painel e telão)
supabase/migrations/
  0001_sala_ao_vivo.sql           schema, RLS, RPCs, Realtime
  0002_telao_e_itens.sql          papel de telão e criação de itens
  0003_corrige_rls_recursiva.sql  correção de recursão nas políticas
```

Rode as migrações **em ordem** no SQL Editor do Supabase. A 0003 é
obrigatória: sem ela, qualquer leitura de `participantes` falha com
recursão infinita e o aluno não consegue entrar na sala.

## Configuração exigida no Supabase

- Authentication → Sign In / Providers → **Anonymous sign-ins habilitado**.
- Região `sa-east-1`.

A chave em `index.html` é a *publishable* (anon). É pública por design: vai
no bundle do navegador e não é segredo. A proteção dos dados é a RLS. A
chave `service_role` não aparece neste repositório e não deve aparecer.

## As três superfícies

| Papel  | URL              | Onde roda           |
|--------|------------------|---------------------|
| Aluno  | `/`              | celular do aluno    |
| Painel | `/?m=painel`     | celular do instrutor|
| Telão  | `/?m=telao`      | notebook projetado  |

**Atenção ao testar:** a identidade anônima fica no `localStorage`, que é por
navegador. Abrir dois papéis no mesmo navegador faz os dois compartilharem a
mesma identidade. Use contextos distintos — Chrome, Firefox e o celular.

## Decisões de projeto

- **Uma fonte de verdade.** A fase da sessão é uma única linha em `sessoes`;
  todas as telas escutam essa linha via Realtime. Evita divergência entre
  telão e celulares.
- **Servidor fecha a janela.** O cronômetro na tela é decorativo; quem barra
  resposta atrasada é o `now()` do Postgres dentro de `sala_responder`.
- **Gabarito nunca sai do banco.** A coluna fica fora do `GRANT` para o papel
  `authenticated`; a correção acontece server-side.
- **Moderação ligada por padrão.** Termo só vai ao telão depois de aprovado.
  O mesmo vale para apelidos, que passam pela blocklist.
- **Sem proctoring.** Sem nota em jogo, registrar o comportamento do aluno é
  vigilância sem finalidade e reduz a participação.
- **Refetch, não delta.** Qualquer evento de Realtime dispara nova consulta.
  Gasta mais queries e elimina uma classe inteira de bugs de dessincronia.

## Pendências

- Quiz e placar ponta a ponta (schema já suporta; falta a interface).
- Migração para Next.js 15 depois da validação em sala.
- Plano free do Supabase pausa o projeto após 7 dias sem atividade.
