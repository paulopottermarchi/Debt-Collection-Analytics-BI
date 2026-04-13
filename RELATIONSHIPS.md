# Power BI Relationship Map

> **25 relacionamentos · todos 1:N · zero many-to-many**
>
> Documentação do modelo analítico da plataforma de cobrança — SQL Server · Power Query · DAX · Power BI

---

## Sumário

1. [Visão Geral](#1-visão-geral)
2. [Dimensões Conformed](#2-dimensões-conformed)
3. [Mapa Completo dos 25 Relacionamentos](#3-mapa-completo-dos-25-relacionamentos)
4. [Detalhamento por Tabela](#4-detalhamento-por-tabela)
   - [Cobrança](#cobrança)
   - [Dialer](#dialer)
   - [Manual](#manual)
   - [Payments](#payments)
   - [Old Vs New](#old-vs-new)
   - [Falta](#falta)
   - [Operadores](#operadores)
   - [CC](#cc)
   - [Case](#case)
   - [Dim_CommissionRules](#dim_commissionrules)
5. [Regras de Modelagem](#5-regras-de-modelagem)
   - [Por que todos os relacionamentos são 1:N?](#51-por-que-todos-os-relacionamentos-são-1n)
   - [DateTable com múltiplos papéis em Cobrança](#52-datetable-com-múltiplos-papéis-em-cobrança)
   - [client_id ≠ company_id](#53-client_id--company_id)
   - [Dialer não tem case_id direto na fonte](#54-dialer-não-tem-case_id-direto-na-fonte)
   - [Anti-patterns evitados](#55-anti-patterns-evitados)

---

## 1. Visão Geral

O modelo Power BI segue o padrão **Star Schema**: tabelas de fatos conectadas a dimensões conformed via chaves 1:N.

```
DateTable ──────────────────────────────────── dimensão temporal
Query1_Ref (Dim_Operator) ────────────────────── dimensão de operadores
Company ──────────────────────────────────────── dimensão de empresas/carteiras
Case ─────────────────────────────────────────── dimensão de contratos
       │              │              │              │
    Cobrança       Dialer         Manual         Payments
    Old Vs New     Falta          Operadores     CC
    Dim_CommissionRules
```

> **Regra fundamental:** toda junção entre domínios passa obrigatoriamente por uma das quatro dimensões conformed. Nunca diretamente entre duas tabelas de fatos.

---

## 2. Dimensões Conformed

| Dimensão | Chave PK | Descrição |
|---|---|---|
| `DateTable` | `Date` | Calendário brasileiro (UTC-3). Colunas DAX: `WeekOfMonth`, `IsBusinessDay`. Usada por 7 tabelas de fatos via role-playing dimensions. |
| `Query1_Ref` | `users_id` | Dim_Operator. Contém `user_id`, `user_name`, `sip_account` e flags derivados `is_operator` / `is_inactive`. |
| `Company` | `client_id` | Empresas e carteiras de cobrança. Atenção: `client_id ≠ company_id` na fonte operacional. |
| `Case` | `case_id` | Contratos individuais de dívida. Sempre referenciado junto com `Company` para evitar junção direta por `debtor_id`. |

---

## 3. Mapa Completo dos 25 Relacionamentos

| # | Tabela Fato / Ponte | Chave FK | Dimensão | Chave PK | Tipo |
|---|---|---|---|---|---|
| 1 | `Case` | `client_id` | `Company` | `client_id` | 1:N |
| 2 | `CC` | `users_id` | `Query1_Ref` | `users_id` | 1:N |
| 3 | `Cobrança` | `case_id` | `Case` | `case_id` | 1:N |
| 4 | `Cobrança` | `client_id` | `Company` | `client_id` | 1:N |
| 5 | `Cobrança` | `contact_date` | `DateTable` | `Date` | 1:N |
| 6 | `Cobrança` | `operator_id` | `Query1_Ref` | `users_id` | 1:N |
| 7 | `Cobrança` | `payment_date` | `DateTable` | `Date` | 1:N |
| 8 | `Cobrança` | `promise_date` | `DateTable` | `Date` | 1:N |
| 9 | `Dialer` | `call_date` | `DateTable` | `Date` | 1:N |
| 10 | `Dialer` | `case_id` | `Case` | `case_id` | 1:N |
| 11 | `Dialer` | `client_id` | `Company` | `client_id` | 1:N |
| 12 | `Dialer` | `operator_id` | `Query1_Ref` | `users_id` | 1:N |
| 13 | `Dim_CommissionRules` | `client_id` | `Company` | `client_id` | 1:N |
| 14 | `Falta` | `users_id` | `Query1_Ref` | `users_id` | 1:N |
| 15 | `Falta` | `WorkDate` | `DateTable` | `Date` | 1:N |
| 16 | `Manual` | `case_id` | `Case` | `case_id` | 1:N |
| 17 | `Manual` | `client_id` | `Company` | `client_id` | 1:N |
| 18 | `Manual` | `contact_day` | `DateTable` | `Date` | 1:N |
| 19 | `Manual` | `operator_id` | `Query1_Ref` | `users_id` | 1:N |
| 20 | `Old Vs New` | `client_id` | `Company` | `client_id` | 1:N |
| 21 | `Old Vs New` | `payment_date` | `DateTable` | `Date` | 1:N |
| 22 | `Operadores` | `Date` | `DateTable` | `Date` | 1:N |
| 23 | `Operadores` | `Operator ID` | `Query1_Ref` | `users_id` | 1:N |
| 24 | `Payments` | `client_id` | `Company` | `client_id` | 1:N |
| 25 | `Payments` | `payment_date` | `DateTable` | `Date` | 1:N |

---

## 4. Detalhamento por Tabela

---

### Cobrança

Tabela de fatos principal. Registra contatos, promessas e pagamentos. Possui **três datas FK** para a `DateTable` (granularidade multi-data), além de vínculos ao operador, empresa e contrato.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `case_id` | `Case` | `case_id` | Liga o fato ao contrato individual de dívida |
| `client_id` | `Company` | `client_id` | Liga o fato à empresa/carteira de cobrança |
| `contact_date` | `DateTable` | `Date` | Filtragem temporal pelo dia do contato |
| `operator_id` | `Query1_Ref` | `users_id` | Identifica o operador responsável pelo contato |
| `payment_date` | `DateTable` | `Date` | Filtragem temporal pelo dia de pagamento |
| `promise_date` | `DateTable` | `Date` | Filtragem temporal pelo dia da promessa |

> ⚠️ As três datas criam **role-playing dimensions** sobre a `DateTable`. Apenas `contact_date` é o relacionamento ativo; `payment_date` e `promise_date` são consultadas via `USERELATIONSHIP()` em medidas DAX específicas.

---

### Dialer

Fato de tentativas de discagem automática. Associa cada chamada a um operador, empresa e contrato.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `call_date` | `DateTable` | `Date` | Filtragem temporal pelo dia da chamada |
| `case_id` | `Case` | `case_id` | Liga a chamada ao contrato |
| `client_id` | `Company` | `client_id` | Liga a chamada à empresa/carteira |
| `operator_id` | `Query1_Ref` | `users_id` | Identifica o operador que realizou a chamada |

> ℹ️ Na fonte (`dtdi.dialer`), não existe `case_id`. O vínculo é construído na camada SQL via join temporal de ±15 minutos entre `phone_id + contract_id`. Ver [seção 5.4](#54-dialer-não-tem-case_id-direto-na-fonte).

---

### Manual

Fato de contatos manuais (WhatsApp, ligação direta, etc.). Estrutura paralela ao Dialer.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `case_id` | `Case` | `case_id` | Liga o contato ao contrato |
| `client_id` | `Company` | `client_id` | Liga o contato à empresa/carteira |
| `contact_day` | `DateTable` | `Date` | Filtragem temporal pelo dia do contato |
| `operator_id` | `Query1_Ref` | `users_id` | Identifica o operador responsável |

---

### Payments

Fato de pagamentos recebidos.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `client_id` | `Company` | `client_id` | Liga o pagamento à empresa/carteira |
| `payment_date` | `DateTable` | `Date` | Filtragem temporal pelo dia do pagamento |

---

### Old Vs New

Fato de classificação de pagamentos em dinheiro novo (NEW) ou antigo (OLD), dentro de uma janela de 30 dias.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `client_id` | `Company` | `client_id` | Liga a classificação à empresa/carteira |
| `payment_date` | `DateTable` | `Date` | Filtragem temporal pelo dia do pagamento |

---

### Falta

Fato de presença/ausência dos operadores. Resultado de cartesian join entre operadores × dias úteis, com LEFT JOIN sobre a atividade real.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `users_id` | `Query1_Ref` | `users_id` | Identifica o operador |
| `WorkDate` | `DateTable` | `Date` | Liga a falta ao dia útil correspondente |

---

### Operadores

Tabela auxiliar de métricas de operadores por dia (produtividade, presença).

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `Date` | `DateTable` | `Date` | Liga ao calendário |
| `Operator ID` | `Query1_Ref` | `users_id` | Liga ao cadastro de operadores |

---

### CC

Tabela de atividade de operadores no CRM — conta contatos por usuário e dia.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `users_id` | `Query1_Ref` | `users_id` | Identifica o operador no CRM |

---

### Case

Dimensão de contratos. Também se relaciona com `Company` para vincular o contrato à empresa dona da carteira.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `client_id` | `Company` | `client_id` | Liga o contrato à empresa/carteira de cobrança |

---

### Dim_CommissionRules

Tabela de regras de comissão por empresa. Usada para calcular o valor de comissão sobre cada pagamento recebido.

| Coluna FK | Dimensão | Chave PK | Propósito |
|---|---|---|---|
| `client_id` | `Company` | `client_id` | Liga a regra de comissão à empresa/carteira |

---

## 5. Regras de Modelagem

### 5.1 Por que todos os relacionamentos são 1:N?

O Power BI propaga filtros da dimensão (lado `1`) para o fato (lado `N`). Relacionamentos M:M exigiriam tabelas ponte adicionais e gerariam ambiguidade nos contextos de filtro DAX. Toda a arquitetura foi desenhada para eliminar esse padrão — cada chave estrangeira de fato aponta para exatamente uma chave primária de dimensão.

---

### 5.2 DateTable com múltiplos papéis em Cobrança

A tabela `Cobrança` conecta três datas diferentes (`contact_date`, `payment_date`, `promise_date`) à mesma `DateTable`. Isso cria **role-playing dimensions**:

- Apenas **um** relacionamento pode estar ativo por vez no modelo
- O relacionamento ativo é `contact_date → DateTable[Date]`
- Os demais são consultados com `USERELATIONSHIP()` dentro de medidas DAX:

```dax
Paid Capital =
CALCULATE(
    SUM(Cobrança[payed_capital]),
    USERELATIONSHIP(Cobrança[payment_date], DateTable[Date])
)
```

---

### 5.3 client_id ≠ company_id

> ⚠️ Na fonte operacional (`dtdi` schema), `client_id` e `company_id` são campos distintos.

A junção correta entre contratos (`Case`) e empresas (`Company`) **sempre usa `client_id`** em ambos os lados. Usar `company_id` como chave de join produz resultados incorretos.

```sql
-- ✅ Correto
JOIN company ON case.client_id = company.client_id

-- ❌ Incorreto
JOIN company ON case.company_id = company.company_id
```

---

### 5.4 Dialer não tem case_id direto na fonte

Na tabela de origem `dtdi.dialer`, não existe `case_id`. O vínculo ao contrato é construído na camada SQL via **join temporal de ±15 minutos**:

```sql
-- Fact_contacts.sql
INNER JOIN dialer_calls d
    ON d.telecom_id = cb.telecom_id
   AND d.case_id    = cb.case_id
   AND d.call_date BETWEEN
        DATEADD(MINUTE, -15, cb.contact_date)
        AND DATEADD(MINUTE,  15, cb.contact_date)
```

Um `ROW_NUMBER()` subsequente mantém apenas o match mais recente por `contact_id`, eliminando fan-out. Após esse join na camada SQL, o `Dialer` no Power BI pode se relacionar normalmente com `Case` e `Company`.

---

### 5.5 Anti-patterns evitados

| Anti-pattern | Por que é problemático |
|---|---|
| Join `Dialer → financeiro` por `debtor_id` | `debtor_id` é chave de pessoa física. Um devedor pode ter múltiplos contratos — gera M:M. |
| `DISTINCT` para deduplicar promessas | Não-determinístico: resultados variam entre execuções dependendo da ordem interna. |
| Métricas financeiras agrupadas por `debtor_id` | Um devedor com múltiplos contratos teria pagamentos somados incorretamente. |
| Inferir ausência pela falta de eventos | No primeiro dia de um operador, ausência de evento seria interpretada como falta — falso positivo. |
| Promessas do Dialer contadas no Manual | Double attribution: a mesma promessa apareceria em dois domínios distintos. |
| Join direto entre duas tabelas de fatos | Sem passar por uma dimensão conformed, o contexto de filtro DAX se torna ambíguo. |

---

*Debt Collection Analytics Platform · Paulo Potter Marchi · SQL Server · Power Query · DAX · Power BI*
