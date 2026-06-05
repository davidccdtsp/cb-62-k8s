import { Injectable, Logger } from '@nestjs/common';
import { Langfuse } from 'langfuse';
import { DataService } from '../shared/data.service';

const rand    = (min: number, max: number) => Math.random() * (max - min) + min;
const randInt = (min: number, max: number) => Math.floor(rand(min, max + 1));
const sleep   = (ms: number) => new Promise(r => setTimeout(r, ms));

@Injectable()
export class AgentService {
  private readonly logger = new Logger(AgentService.name);
  private readonly lf: Langfuse | null;
  private readonly enabled: boolean;

  constructor(private readonly data: DataService) {
    const pk   = process.env.LANGFUSE_PUBLIC_KEY;
    const sk   = process.env.LANGFUSE_SECRET_KEY;
    const host = process.env.LANGFUSE_HOST || 'http://localhost:3001';
    this.enabled = !!(pk && sk);
    if (this.enabled) {
      this.lf = new Langfuse({ publicKey: pk, secretKey: sk, baseUrl: host });
    } else {
      this.lf = null;
      this.logger.warn('Langfuse disabled: LANGFUSE_PUBLIC_KEY or LANGFUSE_SECRET_KEY not set');
    }
  }

  async run(query: string, tenantId: string, runId: string) {
    this.logger.log(`agent run started run_id=${runId} query=${JSON.stringify(query)} tenant_id=${tenantId}`);

    const trace = this.lf?.trace({ id: runId, name: 'agent-run', input: { query }, userId: tenantId, tags: ['agent', 'demo', tenantId] }) ?? null;

    // Step 1: retrieval
    await sleep(rand(50, 150));
    const keywords = query.toLowerCase().split(/\s+/);
    let matches = this.data.products.filter(p =>
      keywords.some(kw => p.name.toLowerCase().includes(kw) || String(p.price).includes(kw)),
    );
    if (!matches.length) matches = [...this.data.products];
    const retrieval = matches.map(p => ({ id: p.id, name: p.name, price: p.price }));
    this.logger.log(`agent retrieval run_id=${runId} matches=${retrieval.length} tenant_id=${tenantId}`);

    trace?.span({ name: 'retrieval', input: { query }, output: { matches: retrieval }, metadata: { total_products: this.data.products.length, matched: retrieval.length } });

    // Step 2: generation (simulated LLM)
    await sleep(rand(200, 500));
    const promptTokens     = randInt(40, 80);
    const completionTokens = randInt(30, 60);
    const model            = 'gpt-4o-mini';
    const catalogText      = matches.map(p => `${p.name} ($${p.price})`).join(', ');
    const systemPrompt     = 'You are a helpful product recommendation assistant. Answer based only on the provided catalog.';
    const userPrompt       = `Catalog: ${catalogText}\n\nQuestion: ${query}`;
    const cheapest         = matches.reduce((a, b) => (a.price < b.price ? a : b));
    const answer           = `Based on the available catalog, I found ${matches.length} relevant product(s): ${catalogText}. The cheapest option is ${cheapest.name}.`;

    this.logger.log(`agent generation run_id=${runId} model=${model} prompt_tokens=${promptTokens} completion_tokens=${completionTokens} tenant_id=${tenantId}`);

    trace?.generation({ name: 'product-recommendation', model, input: [{ role: 'system', content: systemPrompt }, { role: 'user', content: userPrompt }], output: answer, usage: { promptTokens, completionTokens } });
    trace?.update({ output: { answer } });

    if (this.lf) {
      try {
        await Promise.race([this.lf.flushAsync(), sleep(5000)]);
        this.logger.log(`langfuse flush ok run_id=${runId}`);
      } catch (e) {
        this.logger.error(`langfuse flush failed run_id=${runId} error=${e}`);
      }
    }

    this.logger.log(`agent run completed run_id=${runId} tenant_id=${tenantId}`);
    return {
      run_id: runId,
      query,
      tenant_id: tenantId,
      steps: [
        { step: 'retrieval',   matches: retrieval.length },
        { step: 'generation',  model, tokens: promptTokens + completionTokens },
      ],
      answer,
    };
  }
}
