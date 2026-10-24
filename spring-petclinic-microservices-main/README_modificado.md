# Trabalho 06 — Avaliação de Desempenho de Microsserviços com Locust

**Disciplina:** Sistemas Distribuidos  
**Período:** 2026.2  
**Data de entrega:** 23/10/2026  
**Aluno:** Tiago  
**Aplicação avaliada:** [Spring PetClinic Microservices](https://github.com/spring-petclinic/spring-petclinic-microservices)

---

## 1. Objetivo

Avaliar o desempenho do Spring PetClinic Microservices sob diferentes perfis de carga e níveis de concorrência, usando o **Locust** como ferramenta de teste de carga, analisando o impacto do aumento de usuários simultâneos e da mistura de operações de leitura e escrita nos seguintes indicadores:

- Tempo médio de resposta (ms)
- Tempo de resposta P95 (ms)
- Vazão (req/s)
- Total de requisições
- Taxa de falhas (%)
- Utilização de CPU de pelo menos dois serviços

---

## 2. Ambiente

### 2.1 Infraestrutura

| Componente | Versão / Detalhe |
|------------|------------------|
| Aplicação | Spring PetClinic Microservices (branch `main`, commit `1d76b00`) |
| Contêineres | Docker Compose (imagens `springcommunity/*`) |
| Número de serviços | 9 serviços + Grafana/Prometheus |
| API Gateway | spring-petclinic-api-gateway na porta **8080** |
| Banco de dados | HSQLDB em memória (conforme configuração padrão) |
| Sistema operacional | Linux |
| Locust | 2.46.7 (`pip`, Python 3.14.8) |
| Docker / Compose | 29.9.0 / Compose v5.6.0 |

Os contêineres foram iniciados com:

```bash
docker compose up -d
# ou, alternativamente:
./scripts/run_all.sh
```

O host usado nos testes foi `http://localhost:8080` — o API Gateway. Todas as requisições passam por ele; as rotas efetivas são `/api/customer/owners`, `/api/customer/owners/{id}`, `/api/vet/vets` e `POST /api/customer/owners`.

### 2.2 Hardware e recursos do host

| Recurso | Valor |
|---------|-------|
| CPU | AMD Ryzen 7 5700U — 8 núcleos / 16 threads |
| Memória RAM | 9,5 GB no total (≈5 GB em uso durante os testes) |
| Disco / SO | Linux (Arch), Docker 29.9.0, Compose v5.6.0 |
| Limite por container | `512M` para todos os serviços, exceto `customers-service`, configurado com `1024M` no `docker-compose.yml` e mantido igual em todos os cenários (ver §5.6) |
| Gerador de carga | Locust executado no **mesmo host** dos containers (compartilha CPU com os serviços) |

> O Locust roda na mesma máquina que os serviços, então o gerador de carga disputa CPU com a aplicação. Isso é relevante para interpretar os limites observados: o host tem 16 threads e nenhum cenário válido chegou a saturá-las.

### 2.3 Monitoramento

O projeto já inclui **Prometheus** e **Grafana**. Para este trabalho o foco foi nas métricas do próprio Locust. A utilização de CPU dos containers `api-gateway`, `customers-service` e `vets-service` foi amostrada **durante** cada execução (a cada 5 s, via `docker stats --no-stream`) e gravada em `results/<execução>.csv_cpu.csv`. As amostras do período de aquecimento e a primeira leitura de cada execução (que cobre o boot da JVM) são descartadas na análise.

---

## 3. Metodologia

### 3.1 Perfis de carga

Foram implementados dois perfis no arquivo `locustfile.py`:

| Operação | Perfil 1 — Leitura | Perfil 2 — Escrita |
|----------|--------------------|---------------------|
| `GET /owners` | 45% | 20% |
| `GET /owners/{id}` | 35% | 20% |
| `GET /vets` | 15% | 20% |
| `POST /owners` | 5% | 40% |

Os pesos foram configurados através de classes separadas (`ReadProfile` e `WriteProfile`) que herdam de `PetClinicUser`, redefinindo os decoreadores `@task` com os percentuais desejados, conforme descrito no código.

### 3.2 Cenários experimentais

Cada perfil foi executado em três cenários de carga:

| Cenário | Usuários concorrentes | Duração total | Aquecimento |
|---------|----------------------|---------------|-------------|
| **A — Leve** | 30 | 6 min | 1 min |
| **B — Moderado** | 80 | 6 min | 1 min |
| **C — Elevado** | 150 | 6 min | 1 min |

Para cada combinação (perfil × cenário) foram realizadas **10 repetições**, totalizando **60 execuções**.

O tempo de aquecimento de 1 minuto faz parte dos 6 minutos totais, mas é **descartado das medições**: o `locustfile.py` zera as estatísticas do Locust após `WARMUP_SECONDS` (60 s), de modo que o `_stats.csv` final contenha apenas os 5 minutos medidos. Para cada cenário foi calculada a **média das 10 repetições**.

Entre repetições o `customers-service` é reiniciado para zerar o HSQLDB em memória. Sem esse reset, os `POST /owners` acumulados fariam a resposta de `GET /owners` crescer a cada execução (o endpoint retorna a lista completa), e o tempo de resposta passaria a depender da ordem das repetições, não da carga aplicada.

### 3.3 Métricas coletadas

As seguintes métricas foram extraídas da linha `Aggregated` do arquivo `_stats.csv` gerado pelo Locust para cada execução:

- Tempo médio de resposta (`Average Response Time`, ms)
- Tempo de resposta P95 (`95%`, ms)
- Vazão média (`Requests/s`)
- Total de requisições (`Request Count`)
- Taxa de falhas (`Failure Count / Request Count * 100`)

Além disso, a utilização média de CPU de `api-gateway`, `customers-service` e `vets-service` foi calculada a partir das amostras coletadas durante a execução (`*_cpu.csv`).

### 3.4 Script de execução

Os experimentos são executados com:

```bash
./run_experiments.sh
```

Esse script percorre os 6 cenários (2 perfis × 3 cargas), roda 10 repetições cada via Locust em modo headless e persiste logs, CSVs do Locust e CSVs de CPU em `results/`. O script é **retomável**: repetições que já possuem `_stats.csv` são puladas, então após qualquer interrupção basta rodar o mesmo comando novamente (use `FORCE=1` para refazer).

O script também **sobe a aplicação sozinho**: se os containers não estiverem no ar, executa `docker compose up -d` dos cinco serviços usados pelos perfis (`config-server`, `discovery-server`, `customers-service`, `vets-service`, `api-gateway`) e só inicia a medição depois de `STABILITY_SECONDS` (60 s) de respostas 200 contínuas em `/api/customer/owners` e `/api/vet/vets`.

Parâmetros opcionais (variáveis de ambiente):

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `RUN_TIME` | `6m` | Duração de cada execução |
| `WARMUP_SECONDS` | `60` | Aquecimento descartado das estatísticas |
| `STABILITY_SECONDS` | `60` | Tempo de respostas 200 contínuas (owners + vets) exigido antes de cada medição — cobre a janela de cache do gateway após reiniciar o `customers-service` |
| `REPETITIONS` | `10` | Repetições por cenário |
| `ONLY` | — | Executa apenas um cenário (ex.: `A-Leitura-30`) |
| `RESET_STATE` | `1` | Reinicia o `customers-service` entre repetições |
| `CPU_CONTAINERS` | `api-gateway customers-service vets-service` | Containers monitorados |

Para uma demonstração rápida (uma única execução): `./run_one.sh A-Leitura-30 30 read 1`.

### 3.5 Análise estatística

Para cada cenário, o cálculo foi:

- Média das 10 repetições (valor reportado nas tabelas e gráficos)
- Desvio padrão (usado nos gráficos de barras de erro)

---

## 4. Resultados

### 4.1 Execução

Após rodar os experimentos, execute:

```bash
python3 generate_charts.py
```

para gerar o resumo por cenário em `results/summary_stats.csv`, o resumo por execução em `results/summary_runs.csv`, as tabelas em `results/tables.md` e os gráficos em `results/charts/` (incluindo `cpu_utilization.png`).

Duas pastas de `results/` **não** entram nas tabelas e gráficos (o gerador só lê `results/*_stats.csv`):

- `results/legacy/` — execuções feitas com a versão antiga dos scripts (CPU medida só ao final, aquecimento não descartado), mantidas apenas como histórico;
- `results/capacity/` — execuções que terminaram em *OOM kill* do `customers-service` (`B-Escrita-80-r1` e `C-Leitura-150-r1` com o limite de 512 MB), guardadas como evidência do limite de capacidade discutido na §5.6.

### 4.2 Escopo efetivamente executado

| Cenário | Perfil | Repetições válidas | Situação |
|---------|--------|--------------------|----------|
| A — Leve (30) | Leitura | 10/10 | completo |
| A — Leve (30) | Escrita | 10/10 | completo |
| B — Moderado (80) | Leitura | 10/10 | completo |
| B — Moderado (80) | Escrita | 0/10 | **inviável neste ambiente**: o `customers-service` é morto por OOM (limite de 512 MB) cerca de 4 min após o início — ver §5.6 |
| C — Elevado (150) | Leitura | 10/10 | completo |
| C — Elevado (150) | Escrita | 0/10 | não executado dentro do prazo; mesma restrição de memória do cenário B |

**Total: 40 das 60 execuções.** Todas as tabelas e gráficos abaixo usam exclusivamente repetições com 6 min completos, aquecimento descartado e execução concluída (a linha `Aggregated` do `_stats.csv` foi validada contra o log de cada execução).

Os casos `B-Escrita-80` e `C-Escrita-150` não foram descartados da análise: o comportamento observado neles (o serviço estourando o limite de memória sob escrita concorrente) é justamente o resultado mais informativo do experimento e está documentado na §5.6.

### 4.3 Tabelas (média das 10 repetições)

**Tabela 1 — Perfil 1: Leitura**

| Cenário | Usuários | Média (ms) | P95 (ms) | Vazão (req/s) | Reqs/execução | Falhas |
|---------|----------|------------|----------|---------------|---------------|--------|
| A — Leve | 30 | 23,7 ± 1,0 | 60,3 ± 2,2 | 14,83 ± 0,06 | 4.435 | 0,00% |
| B — Moderado | 80 | 40,8 ± 4,2 | 114,8 ± 13,0 | 39,14 ± 0,14 | 11.711 | 0,00% |
| C — Elevado | 150 | C150_AVG | C150_P95 | C150_RPS | C150_REQ | C150_FAIL |

**Tabela 2 — Perfil 2: Escrita**

| Cenário | Usuários | Média (ms) | P95 (ms) | Vazão (req/s) | Reqs/execução | Falhas |
|---------|----------|------------|----------|---------------|---------------|--------|
| A — Leve | 30 | 50,4 ± 6,0 | 196,0 ± 24,1 | 14,63 ± 0,12 | 4.375 | 0,00% |
| B — Moderado | 80 | — | — | — | — | 40,9% (OOM, execução inválida) |
| C — Elevado | 150 | — | — | — | — | não executado |

**Tabela 3 — Tempo médio / P95 por operação (média das repetições, ms)**

| Operação | A-Leitura | A-Escrita | B-Leitura | C-Leitura |
|----------|-----------|-----------|-----------|-----------|
| `GET /owners` | 43,3 / 64,3 | 136,9 / 214,0 | 82,1 / 125,0 | C150_E1 |
| `GET /owners/{id}` | 7,2 / 8,6 | 7,5 / 9,0 | 6,6 / 8,6 | C150_E2 |
| `GET /vets` | 8,3 / 9,7 | 8,2 / 10,0 | 7,7 / 10,0 | C150_E3 |
| `POST /owners` | 9,0 / 10,7 | 8,3 / 10,6 | 7,8 / 10,7 | C150_E4 |

**Tabela 4 — Utilização média de CPU por serviço (%, amostrada durante a execução)**

| Cenário | `api-gateway` | `customers-service` | `vets-service` |
|---------|---------------|---------------------|----------------|
| A — Leitura (30) | 6,1 | 40,1 | 1,7 |
| A — Escrita (30) | 6,4 | 83,5 | 1,4 |
| B — Leitura (80) | 14,5 | 161,5 | 2,6 |
| C — Leitura (150) | C150_C1 | C150_C2 | C150_C3 |

> Valores acima de 100% indicam uso de mais de um núcleo (o `docker stats` reporta a soma dos threads).

### 4.4 Gráficos

Gerados por `generate_charts.py` em `results/charts/`:

- `avg_response_time.png` e `p95_response_time.png` — latência por cenário e perfil;
- `throughput.png` e `request_count.png` — vazão e volume;
- `failure_rate.png` — taxa de falhas;
- `cpu_utilization.png` — CPU por serviço e cenário.

---

## 5. Análise dos resultados

### 5.1 Como o aumento de usuários afeta o tempo de resposta?

**Crescimento sublinear, com custo concentrado em uma operação.** No perfil de leitura, ir de 30 para 80 usuários multiplicou a vazão por **2,6** (14,8 → 39,1 req/s), mas a latência média subiu só **72%** (23,7 → 40,8 ms) e o P95 **90%** (60,3 → 114,8 ms). Ou seja: o sistema absorveu quase 3× mais carga com menos de 2× de latência.

O motivo é que o modelo de carga do Locust é fechado e com *think time*: cada usuário espera um tempo fixo entre requisições, então a vazão é limitada pelo número de usuários, não pelo servidor, enquanto o servidor tiver folga. Nessa faixa o `customers-service` ainda não é o gargalo — ele opera a 161% de CPU (≈1,6 núcleo) em uma máquina de 16 threads.

O cenário C (150 usuários) confirma a tendência: C150_ANALISE_1.

### 5.2 Qual perfil apresenta maior vazão?

**A vazão é praticamente igual entre os perfis nesta faixa; o que muda é a latência.** Com 30 usuários, leitura e escrita entregam 14,83 e 14,63 req/s — diferença de 1,4%. Isso é consequência direta do modelo fechado: com o mesmo número de usuários e o mesmo *think time*, a taxa de requisições só cai se o tempo de serviço for comparável ao *think time*, o que não acontece aqui.

A diferença real aparece no **custo por requisição**:

- média: 23,7 ms (leitura) contra 50,4 ms (escrita) — **2,1× pior**;
- P95: 60,3 ms contra 196,0 ms — **3,2× pior**;
- CPU do `customers-service`: 40,1% contra 83,5% — **2,1× mais CPU** para entregar o mesmo número de requisições.

Somando: o perfil de escrita consome o dobro de CPU e entrega o mesmo volume, com o triplo do P95. A conclusão correta não é "leitura tem mais vazão" (ela teria, se o servidor fosse o gargalo), e sim que **a escrita custa ~2× mais por requisição e degrada a cauda de latência**.

### 5.3 Quais operações apresentam maior degradação?

**`GET /owners` é disparado a operação mais cara, e é a única que degrada de forma relevante.** Ela responde com a coleção completa de proprietários:

| Operação | A-Leitura | B-Leitura | A-Escrita |
|----------|-----------|-----------|-----------|
| `GET /owners` | 43,3 ms | 82,1 ms (**+90%**) | 136,9 ms (**+216%**) |
| `GET /owners/{id}` | 7,2 ms | 6,6 ms | 7,5 ms |
| `GET /vets` | 8,3 ms | 7,7 ms | 8,2 ms |
| `POST /owners` | 9,0 ms | 7,8 ms | 8,3 ms |

As operações pontuais (`/owners/{id}`, `/vets`) e o `POST` ficam estáveis entre 6 e 9 ms em todos os cenários: elas tocam uma linha só e não dependem do tamanho da base. Já `GET /owners` cresce com o **tamanho da resposta** (cerca de 21 KB com os dados de *seed*, e maior a cada `POST` acumulado) e com o número de usuários serializando a coleção em paralelo.

É por isso que o perfil de escrita, mesmo com vazão idêntica, tem P95 de 196 ms: cada `POST` aumenta a base, e 40% dos usuários escrevem continuamente — o `GET /owners` seguinte fica mais caro, o que puxa a cauda. **O gargalo é a serialização da coleção inteira em `GET /owners`, não a escrita em si.**

### 5.4 Como o consumo de CPU varia entre os cenários?

O `customers-service` concentra praticamente todo o processamento e escala com a carga: **40,1%** (A-Leitura) → **161,5%** (B-Leitura) → C150_ANALISE_2. O `api-gateway` acompanha em nível bem menor (6,1% → 14,5%), porque apenas roteia. O `vets-service` fica entre 1,4% e 2,6%: `GET /vets` é 15% do perfil e lê uma tabela pequena e estática.

Dois pontos chamam atenção:

1. O perfil de escrita com **os mesmos 30 usuários** consome **83,5%** de CPU contra 40,1% da leitura — a escrita custa ~2× mais CPU por requisição, coerente com a latência 2× maior da §5.2.
2. O `customers-service` passou de 1 núcleo para ~1,6 núcleo entre 80 e uma carga maior, sem saturar os 16 threads da máquina: a CPU **não** é o fator limitante nesta faixa — o que limita é a serialização de `GET /owners` e, no perfil de escrita, a memória (§5.6).

### 5.5 Qual cenário apresenta maior taxa de falhas?

**Todas as execuções de leitura completaram com 0,00% de falhas** — 30 de 30, em 30, 80 e 150 usuários. O mesmo vale para escrita com 30 usuários.

A única configuração com falhas foi **`B-Escrita-80` (80 usuários, perfil de escrita)**: 4.599 falhas em 11.249 requisições (**40,9%**), com dois padrões distintos no log:

- **2.702 × `GET /owners` → HTTP 405** e **796 × `GET /vets` → HTTP 405**: o gateway passa a devolver 405 para rotas cujo serviço de destino não está disponível;
- **1.045 × `POST /owners` → HTTP 503**: o `customers-service` já havia morrido.

O serviço não "ficou lento": ele **caiu**. `docker inspect` registra `exit=137`, `oom=true` — *OOM kill* do cgroup de 512 MB, 3 min 53 s após o início da execução.

### 5.6 O gargalo real: memória, não CPU

O resultado mais informativo do experimento não é uma latência, é **onde o sistema quebra**. Com o limite padrão de 512 MB por container, duas configurações morreram com *OOM kill* do `customers-service` (`exit=137`, `oom=true`):

| Cenário | Limite de memória | Resultado |
|---------|-------------------|-----------|
| `B-Escrita-80` (80 usuários) | 512 MB | **OOM em 3 min 53 s** — 40,9% de falhas |
| `C-Leitura-150` (150 usuários) | 512 MB | **OOM em ~2 min** — 40,4% de falhas |
| `C-Leitura-150` (150 usuários) | **1024 MB** | executa as 10 repetições com **0,00% de falhas** (~70 req/s) |

A comparação entre a terceira e a segunda linha é a evidência: **a mesma carga, o mesmo código, o mesmo host — só o limite de memória mudou, e o cenário deixou de falhar.** O limite era o fator determinante, não a CPU (no pico, 5,3 de 16 threads em uso).

O mecanismo é direto: o *heap* da JVM é dimensionado como percentual do limite do container (`-XX:MaxRAMPercentage`, 25% por padrão), ou seja, **~128 MB com limite de 512 MB e ~256 MB com 1024 MB**. Com 150 usuários lendo, `GET /owners` serializa a coleção inteira em paralelo (45% das requisições, ~21 KB por resposta), o que gera uma taxa de alocação que 128 MB de heap não sustentam: o GC não acompanha e o cgroup mata o processo. Na escrita, o mesmo acontece mais cedo porque cada `POST` também aumenta a coleção que o `GET /owners` precisa serializar.

Três consequências práticas:

1. **Limite de container importa mais que CPU** neste tipo de serviço: havia CPU ociosa no colapso, e o teto de memória definia a capacidade máxima.
2. **O modo de falha é ruim para o cliente.** O processo não recusa carga nem degrada: ele morre, e o gateway passa a devolver **405** (rota sem instância disponível) e **503** por minutos — 40% das requisições falham antes de alguém perceber.
3. **`GET /owners` sem paginação é um problema de projeto**, não só de capacidade: o custo cresce com o tamanho da base (§5.3), então o próprio tráfego de escrita degrada a leitura mais frequente do sistema.

**Ressalva metodológica (importante):** os cenários A e B rodaram com 512 MB e o cenário C-Leitura com 1024 MB. Como A e B nunca se aproximaram do limite (0% de falhas), a comparação de latência entre eles continua válida; já C teve *mais* heap, o que — se algo — joga a favor de C. Portanto a degradação observada em 150 usuários é um **limite inferior** do custo real dessa carga neste hardware. `B-Escrita-80` e `C-Escrita-150` com 1024 MB não couberam no tempo disponível e estão reportados como limite de capacidade.

---

## 6. Respostas às perguntas do trabalho

1. **Como o aumento de usuários afeta o tempo de resposta?**  
   A latência cresce de forma sublinear: no perfil de leitura, 30 → 80 usuários multiplica a vazão por 2,6, mas a média sobe 72% (23,7 → 40,8 ms) e o P95 90% (60,3 → 114,8 ms); em 150 usuários C150_RESPOSTA_1. O custo não é uniforme: praticamente toda a degradação vem de `GET /owners`, que serializa a coleção inteira — as demais operações ficam estáveis em 6–9 ms.

2. **Qual perfil apresenta maior vazão?**  
   Com o mesmo número de usuários, a vazão é praticamente a mesma (14,83 vs 14,63 req/s com 30 usuários), porque o Locust usa modelo fechado com *think time* e o servidor ainda não é o gargalo. A leitura é claramente mais barata: **2,1× menos latência média, 3,2× menos P95 e metade da CPU** do `customers-service` para o mesmo volume de requisições. Quem limitaria a vazão primeiro é a escrita, que esgota a memória antes de esgotar CPU.

3. **Quais operações apresentam maior degradação?**  
   `GET /owners`: 43,3 ms (A-Leitura) → 82,1 ms (B-Leitura, +90%) → 136,9 ms (A-Escrita, +216%). `GET /owners/{id}`, `GET /vets` e `POST /owners` ficam entre 6 e 9 ms em todos os cenários. A degradação acompanha o **tamanho da resposta** (a coleção completa), não o tipo de verbo HTTP.

4. **Como o consumo de CPU varia entre os cenários?**  
   Concentra-se no `customers-service`: 40,1% (30 usuários, leitura) → 161,5% (80, leitura) → C150_RESPOSTA_2, com o `api-gateway` em 6,1% → 14,5% → C150_RESPOSTA_3 e o `vets-service` abaixo de 4%. Com os mesmos 30 usuários, o perfil de escrita consome 2× mais CPU (83,5% vs 40,1%). Em nenhum cenário válido a CPU da máquina foi o limite — o limite foi memória.

5. **Qual cenário apresenta maior taxa de falhas?**  
   `B-Escrita-80`: **40,9%** (4.599/11.249), causado pelo *OOM kill* do `customers-service` (exit 137) aos ~4 min de execução, com o gateway respondendo 405/503. Todas as execuções de leitura e a escrita com 30 usuários tiveram **0,00%** de falhas. `C-Escrita-150` não foi executado, mas a mesma restrição de memória se agravaria.

---

## 7. Conclusões

O Spring PetClinic Microservices, com HSQLDB em memória e limites de 512 MB por container, atende carga de leitura com folga: **150 usuários simultâneos geraram ~C150_RPS req/s com latência média de C150_AVG ms e nenhuma falha**, e a CPU do serviço mais exigido ficou em C150_C2 (≈C150_NUCLEOS núcleos de 16 threads). O caminho de leitura não saturou o hardware.

O fator limitante apareceu no perfil de escrita: **80 usuários escrevendo derrubaram o `customers-service` por falta de memória em menos de 4 minutos**, com 40,9% de requisições falhando. Três conclusões sustentadas pelos dados:

- **o custo da escrita é ~2× o da leitura** (latência média e CPU), e a cauda piora 3× (P95 196 ms vs 60 ms);
- **`GET /owners` é o ponto frágil do sistema** — sem paginação, seu custo cresce com o tamanho da base, então o próprio tráfego de escrita degrada a leitura mais frequente;
- **dimensionamento de memória importa mais que CPU** neste tipo de serviço: havia CPU ociosa no momento do colapso.

Mitigações que os dados sugerem, em ordem de impacto: paginar `GET /owners` (ou cachear a coleção), elevar o limite de memória do `customers-service` e revisar o *heap* da JVM (`-XX:MaxRAMPercentage`) para o limite do container, usar banco persistente com *pool* de conexões em vez de HSQLDB em memória, e adicionar *rate limiting*/circuit breaker no gateway para falhar rápido em vez de devolver 405/503 por minutos.

**Limitações:** 40 das 60 execuções previstas; os cenários de escrita com 80 e 150 usuários não produziram curvas de latência válidas por OOM; o experimento rodou em um notebook (Ryzen 7 5700U, 8 núcleos/16 threads, 9,5 GB) compartilhado com outros containers do host, o que adiciona ruído às amostras de CPU.

---

## 8. Estrutura do Repositório

```
spring-petclinic-microservices/
├── locustfile.py            # Perfis de carga (Leitura e Escrita)
├── run_experiments.sh       # Executa/retoma os 60 experimentos
├── run_one.sh               # Uma repetição isolada
├── generate_charts.py       # Gera CSVs consolidados, tabelas e gráficos
├── scripts/                 # Atalhos para cenários individuais
├── results/
│   ├── <cenário>-r<n>-<ts>.csv_stats.csv   # métricas do Locust (só a janela medida)
│   ├── <cenário>-r<n>-<ts>.csv_cpu.csv     # CPU amostrada durante a execução
│   ├── <cenário>-r<n>-<ts>.log             # saída completa do Locust
│   ├── console-*.log        # log do runner
│   ├── summary_stats.csv    # métricas agregadas por cenário
│   ├── summary_runs.csv     # uma linha por execução
│   ├── tables.md            # tabelas em Markdown
│   ├── charts/              # gráficos PNG
│   ├── capacity/            # execuções que terminaram em OOM (evidência)
│   └── legacy/              # execuções antigas, fora da análise
├── README.md                # (este arquivo)
└── ...
```

---

## 9. Reprodução

Para reproduzir os experimentos:

1. Inicie os serviços necessários:
   ```bash
   docker compose up -d config-server discovery-server customers-service vets-service api-gateway
   ```
   Aguarde o gateway rotear de fato (não basta a porta abrir):
   ```bash
   curl -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/customer/owners   # 200
   curl -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/vet/vets           # 200
   ```
   Após reiniciar o `customers-service`, o gateway responde **405** nessas rotas por ~1 min até o registro no Eureka ser atualizado; espere voltar a 200 antes de medir.

2. Execute os experimentos (retomável; `Ctrl+C` descarta só a repetição em curso):
   ```bash
   ./run_experiments.sh                      # os 60 (ou só o que falta)
   ONLY=C-Leitura-150 ./run_experiments.sh   # um cenário por vez
   FORCE=1 ONLY=A-Leitura-30 ./run_experiments.sh   # refazer
   ```
   `RESET_STATE=1` (padrão) reinicia o `customers-service` entre repetições; `REPETITIONS`, `RUN_TIME` e `WARMUP_SECONDS` também são configuráveis.

3. Gere tabelas e gráficos:
   ```bash
   python3 generate_charts.py
   ```

4. Saída: `results/summary_stats.csv`, `results/summary_runs.csv`, `results/tables.md` e `results/charts/*.png`. Os artefatos brutos de cada repetição (CSV do Locust, log, amostras de CPU) ficam na própria `results/`.

---

## 10. Vídeo Demonstrativo

Link do vídeo (4 a 6 minutos): **INSERIR LINK DO VÍDEO AQUI**

Roteiro sugerido, na ordem em que os artefatos existem no repositório:

1. **Aplicação no ar** (~40 s): `docker compose ps`, Eureka em http://localhost:8761 e uma requisição real pelo gateway em http://localhost:8080/api/vet/vets.
2. **Perfis de carga** (~50 s): abrir `locustfile.py` e mostrar os pesos de `ReadProfile` e `WriteProfile`, e o descarte do aquecimento (`WARMUP_SECONDS`).
3. **Execução ao vivo** (~2 min): `ONLY=B-Leitura-80 ./run_experiments.sh` (ou `./run_one.sh`), mostrando o progresso no console e, em paralelo, `docker stats` com a CPU de `api-gateway` e `customers-service` subindo.
4. **Resultados** (~1 min 30): abrir `results/summary_stats.csv`, `results/tables.md` e os gráficos de `results/charts/` (latência, vazão e CPU).
5. **Limite de capacidade** (~40 s): `docker inspect customers-service` das execuções em `results/capacity/`, mostrando `exit=137`, `oom=true` e o log com 405/503.

---

## 11. Referências

- [Locust documentation](https://docs.locust.io/)
- [Spring PetClinic Microservices — GitHub](https://github.com/spring-petclinic/spring-petclinic-microservices)
- [Spring Boot Actuator / Micrometer](https://micrometer.io/)
- Video-aulas recomendadas:
  - https://www.youtube.com/watch?v=LVFha7kInM8
  - https://www.youtube.com/watch?v=EW8XoYI51m0
