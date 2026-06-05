import { Injectable } from '@nestjs/common';
import { metrics, trace } from '@opentelemetry/api';

@Injectable()
export class TelemetryService {
  private readonly counter = metrics
    .getMeter('backend-nest')
    .createCounter('backend_requests_total', {
      description: 'Total requests by tenant and endpoint',
    });

  record(tenantId: string, endpoint: string): void {
    this.counter.add(1, { 'tenant.id': tenantId, endpoint });
    trace.getActiveSpan()?.setAttribute('tenant.id', tenantId);
  }
}
