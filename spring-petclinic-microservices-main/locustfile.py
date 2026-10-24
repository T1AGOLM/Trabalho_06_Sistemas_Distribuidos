"""
Locust load test para Spring PetClinic Microservices
--------------------------------------------------------
Trabalho 06 — Avaliação de Desempenho de Microsserviços

Implementa os dois perfis de carga solicitados:
  - Perfil 1 (Leitura): 45% GET /owners, 35% GET /owners/{id}, 15% GET /vets, 5% POST
  - Perfil 2 (Escrita): 20% GET /owners, 20% GET /owners/{id}, 20% GET /vets, 40% POST

Todo o tráfego passa pelo API Gateway (porta 8080):
  GET  /api/customer/owners      -> customers-service /owners
  GET  /api/customer/owners/{id} -> customers-service /owners/{id}
  GET  /api/vet/vets             -> vets-service /vets
  POST /api/customer/owners      -> customers-service /owners

Aquecimento: o Locust não descarta o aquecimento nativamente. Este arquivo
zera as estatísticas depois de WARMUP_SECONDS segundos (padrão: 60), de modo
que os arquivos *_stats.csv contenham somente o período de medição.
Defina WARMUP_SECONDS=0 para desativar (útil em execuções curtas de teste).

Execução:
  locust -f locustfile.py --headless -u 30 -r 10 --run-time 6m \
         --host http://localhost:8080 ReadProfile
"""

import logging
import os
import random

import gevent
from locust import HttpUser, between, events, task

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
BASE = "/api"

# Tempo (em segundos) de aquecimento descartado das estatísticas.
WARMUP_SECONDS = int(os.getenv("WARMUP_SECONDS", "60"))

FIRST_NAMES = [
    "João", "Maria", "Pedro", "Ana", "Lucas", "Julia", "Bruno",
    "Camila", "Rafael", "Fernanda", "Gabriel", "Beatriz",
]
LAST_NAMES = [
    "Silva", "Souza", "Oliveira", "Santos", "Rodrigues",
    "Fernandes", "Alves", "Pereira", "Lima", "Costa",
]
CITIES = [
    "São Paulo", "Rio de Janeiro", "Belo Horizonte",
    "Curitiba", "Porto Alegre", "Salvador", "Brasília",
]
ADDRESSES = [
    "Rua das Flores, 123",
    "Av. Brasil, 456",
    "Rua do Sol, 789",
    "Rua da Lua, 321",
    "Travessa das Estrelas, 55",
]
TELEPHONES = [f"{random.randint(100, 999)}{random.randint(100, 999)}{random.randint(1000, 9999)}" for _ in range(50)]


def new_owner_payload():
    """Retorna um payload JSON válido para POST /owners."""
    return {
        "firstName": random.choice(FIRST_NAMES),
        "lastName": random.choice(LAST_NAMES),
        "address": random.choice(ADDRESSES),
        "city": random.choice(CITIES),
        "telephone": random.choice(TELEPHONES),
    }


# ---------------------------------------------------------------------------
# Descarte do aquecimento
# ---------------------------------------------------------------------------
# Zera as estatísticas depois do período de aquecimento para que o resumo
# final (_stats.csv) contenha apenas a janela de medição. O reset também
# reinicia o start_time de cada entrada, portanto Requests/s e percentis
# passam a refletir somente os minutos medidos.
# ---------------------------------------------------------------------------
@events.init.add_listener
def _reset_stats_after_warmup(environment, **_kwargs):
    if WARMUP_SECONDS <= 0:
        return

    def _reset_later():
        gevent.sleep(WARMUP_SECONDS)
        environment.stats.reset_all()
        logging.getLogger("locust.warmup").info(
            "Aquecimento de %ss concluído: estatísticas zeradas, iniciando medição.",
            WARMUP_SECONDS,
        )

    gevent.spawn(_reset_later)


# ---------------------------------------------------------------------------
# Classe base com os quatro endpoints
# ---------------------------------------------------------------------------
class PetClinicUser(HttpUser):
    """Usuário base. Os pesos por perfil são definidos nas subclasses."""

    # Tempo de "pensamento" entre tarefas: 1–3 s.
    wait_time = between(1, 3)

    # Evita que uma requisição pendurada impeça o Locust de encerrar.
    network_timeout = 30

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.owner_id = None  # ID válido obtido dinamicamente

    # ------------------------------------------------------------------
    # Tarefas individuais (peso = frequência relativa)
    # ------------------------------------------------------------------

    @task(45)
    def get_owners(self):
        """GET /owners — lista todos os proprietários."""
        with self.client.get(f"{BASE}/customer/owners", name="GET /owners", catch_response=True) as resp:
            if resp.status_code == 200:
                resp.success()
            else:
                resp.failure(f"status={resp.status_code}")

    @task(35)
    def get_owner_by_id(self):
        """GET /owners/{id} — busca um proprietário pelo ID."""
        if self.owner_id is None:
            self.owner_id = self._pick_owner_id()
        if self.owner_id is None:
            return

        with self.client.get(
            f"{BASE}/customer/owners/{self.owner_id}",
            name="GET /owners/{id}",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                resp.success()
            else:
                # ID inválido (ex.: base reiniciada) — descarta o cache.
                self.owner_id = None
                resp.failure(f"status={resp.status_code}")

    @task(15)
    def get_vets(self):
        """GET /vets — lista todos os veterinários (via API Gateway)."""
        with self.client.get(f"{BASE}/vet/vets", name="GET /vets", catch_response=True) as resp:
            if resp.status_code == 200:
                resp.success()
            else:
                resp.failure(f"status={resp.status_code}")

    @task(5)
    def post_owner(self):
        """POST /owners — cria um novo proprietário."""
        payload = new_owner_payload()
        with self.client.post(
            f"{BASE}/customer/owners",
            json=payload,
            name="POST /owners",
            catch_response=True,
        ) as resp:
            if resp.status_code in (200, 201):
                resp.success()
                try:
                    body = resp.json()
                    if isinstance(body, dict) and "id" in body:
                        self.owner_id = body["id"]
                except Exception:
                    pass
            else:
                resp.failure(f"status={resp.status_code}")

    # ------------------------------------------------------------------
    # Auxiliar
    # ------------------------------------------------------------------
    def _pick_owner_id(self):
        """Obtém um ID de proprietário existente a partir da listagem."""
        with self.client.get(
            f"{BASE}/customer/owners",
            name="GET /owners",
            catch_response=True,
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"status={resp.status_code}")
                return None
            resp.success()
            try:
                owners = resp.json()
            except Exception:
                return None
            if isinstance(owners, list) and owners:
                return random.choice(owners).get("id")
        return None


# ---------------------------------------------------------------------------
# Perfis de carga
# ---------------------------------------------------------------------------
class ReadProfile(PetClinicUser):
    """
    Perfil 1 — Leitura (GET-heavy)
    GET /owners 45% | GET /owners/{id} 35% | GET /vets 15% | POST /owners 5%
    """


class WriteProfile(PetClinicUser):
    """
    Perfil 2 — Escrita (POST-heavy)
    GET /owners 20% | GET /owners/{id} 20% | GET /vets 20% | POST /owners 40%
    """

    @task(20)
    def get_owners(self):
        super().get_owners()

    @task(20)
    def get_owner_by_id(self):
        super().get_owner_by_id()

    @task(20)
    def get_vets(self):
        super().get_vets()

    @task(40)
    def post_owner(self):
        super().post_owner()
