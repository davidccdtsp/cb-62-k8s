import asyncio
import logging
import os
import random
import uuid
from typing import List, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

try:
    from langfuse import Langfuse
    _lf = Langfuse(
        public_key=os.environ.get("LANGFUSE_PUBLIC_KEY", ""),
        secret_key=os.environ.get("LANGFUSE_SECRET_KEY", ""),
        host=os.environ.get("LANGFUSE_HOST", "http://localhost:3001"),
    )
    LANGFUSE_ENABLED = bool(
        os.environ.get("LANGFUSE_PUBLIC_KEY") and os.environ.get("LANGFUSE_SECRET_KEY")
    )
except Exception as e:
    logger.error("Langfuse init failed: %s", e)
    _lf = None
    LANGFUSE_ENABLED = False

if not LANGFUSE_ENABLED:
    logger.warning("Langfuse disabled: LANGFUSE_PUBLIC_KEY or LANGFUSE_SECRET_KEY not set")

app = FastAPI(
    title="Demo Backend",
    description="Servicio de demostración para observabilidad con OpenTelemetry + Grafana",
    version="1.0.0",
)

PRODUCTS = [
    {"id": 1, "name": "Widget A", "price": 9.99, "stock": 100},
    {"id": 2, "name": "Widget B", "price": 19.99, "stock": 50},
    {"id": 3, "name": "Gadget X", "price": 49.99, "stock": 25},
    {"id": 4, "name": "Gadget Y", "price": 99.99, "stock": 10},
]

ORDERS: List[dict] = [
    {"id": 1, "product_id": 1, "quantity": 2, "status": "completed"},
    {"id": 2, "product_id": 3, "quantity": 1, "status": "pending"},
]


class OrderCreate(BaseModel):
    product_id: int
    quantity: int


class AgentQuery(BaseModel):
    query: str


@app.get("/health", tags=["ops"])
async def health():
    return {"status": "ok"}


@app.get("/products", tags=["products"])
async def list_products():
    await asyncio.sleep(random.uniform(0.01, 0.1))
    logger.info("listing products count=%d", len(PRODUCTS))
    return PRODUCTS


@app.get("/products/{product_id}", tags=["products"])
async def get_product(product_id: int):
    await asyncio.sleep(random.uniform(0.01, 0.15))
    product = next((p for p in PRODUCTS if p["id"] == product_id), None)
    if not product:
        logger.warning("product not found product_id=%d", product_id)
        raise HTTPException(status_code=404, detail="Product not found")
    logger.info("retrieved product product_id=%d", product_id)
    return product


@app.get("/orders", tags=["orders"])
async def list_orders():
    await asyncio.sleep(random.uniform(0.05, 0.2))
    logger.info("listing orders count=%d", len(ORDERS))
    return ORDERS


@app.post("/orders", status_code=201, tags=["orders"])
async def create_order(order: OrderCreate):
    await asyncio.sleep(random.uniform(0.1, 0.3))
    product = next((p for p in PRODUCTS if p["id"] == order.product_id), None)
    if not product:
        logger.warning("order creation failed: product not found product_id=%d", order.product_id)
        raise HTTPException(status_code=404, detail="Product not found")
    if product["stock"] < order.quantity:
        logger.warning("order creation failed: insufficient stock product_id=%d", order.product_id)
        raise HTTPException(status_code=409, detail="Insufficient stock")
    new_order = {
        "id": len(ORDERS) + 1,
        "product_id": order.product_id,
        "quantity": order.quantity,
        "status": "pending",
    }
    ORDERS.append(new_order)
    logger.info("order created order_id=%d product_id=%d", new_order["id"], order.product_id)
    return new_order


@app.get("/users", tags=["users"])
async def list_users():
    await asyncio.sleep(random.uniform(0.02, 0.12))
    users = [
        {"id": 1, "name": "Alice", "email": "alice@example.com"},
        {"id": 2, "name": "Bob", "email": "bob@example.com"},
    ]
    logger.info("listing users count=%d", len(users))
    return users


@app.post("/agent/run", tags=["agent"])
async def agent_run(body: AgentQuery):
    run_id = str(uuid.uuid4())
    logger.info("agent run started run_id=%s query=%r", run_id, body.query)

    trace = _lf.trace(
        id=run_id,
        name="agent-run",
        input={"query": body.query},
        tags=["agent", "demo"],
    ) if LANGFUSE_ENABLED else None

    # --- Step 1: retrieval ---
    await asyncio.sleep(random.uniform(0.05, 0.15))
    keywords = body.query.lower().split()
    matches = [
        p for p in PRODUCTS
        if any(kw in p["name"].lower() for kw in keywords)
        or any(kw in str(p["price"]) for kw in keywords)
    ]
    if not matches:
        matches = PRODUCTS
    retrieval_result = [{"id": p["id"], "name": p["name"], "price": p["price"]} for p in matches]
    logger.info("agent retrieval run_id=%s matches=%d", run_id, len(retrieval_result))

    if trace:
        trace.span(
            name="retrieval",
            input={"query": body.query},
            output={"matches": retrieval_result},
            metadata={"total_products": len(PRODUCTS), "matched": len(retrieval_result)},
        )

    # --- Step 2: generation (simulated LLM) ---
    await asyncio.sleep(random.uniform(0.2, 0.5))
    prompt_tokens = random.randint(40, 80)
    completion_tokens = random.randint(30, 60)
    model = "gpt-4o-mini"

    catalog_text = ", ".join(f"{p['name']} (${p['price']})" for p in matches)
    system_prompt = (
        "You are a helpful product recommendation assistant. "
        "Answer based only on the provided catalog."
    )
    user_prompt = f"Catalog: {catalog_text}\n\nQuestion: {body.query}"
    answer = (
        f"Based on the available catalog, I found {len(matches)} relevant product(s): "
        f"{catalog_text}. "
        f"{'The cheapest option is ' + min(matches, key=lambda p: p['price'])['name'] + '.' if matches else ''}"
    )

    logger.info(
        "agent generation run_id=%s model=%s prompt_tokens=%d completion_tokens=%d",
        run_id, model, prompt_tokens, completion_tokens,
    )

    if trace:
        trace.generation(
            name="product-recommendation",
            model=model,
            input=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            output=answer,
            usage={"promptTokens": prompt_tokens, "completionTokens": completion_tokens},
        )
        trace.update(output={"answer": answer})
        try:
            await asyncio.wait_for(
                asyncio.get_event_loop().run_in_executor(None, _lf.flush),
                timeout=5.0,
            )
            logger.info("langfuse flush ok run_id=%s", run_id)
        except asyncio.TimeoutError:
            logger.warning("langfuse flush timeout run_id=%s", run_id)
        except Exception as e:
            logger.error("langfuse flush failed run_id=%s error=%s", run_id, e)

    logger.info("agent run completed run_id=%s", run_id)
    return {
        "run_id": run_id,
        "query": body.query,
        "steps": [
            {"step": "retrieval", "matches": len(retrieval_result)},
            {"step": "generation", "model": model, "tokens": prompt_tokens + completion_tokens},
        ],
        "answer": answer,
    }
