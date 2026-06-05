import { Controller, Post, Body, Logger } from '@nestjs/common';
import { ApiTags, ApiBearerAuth } from '@nestjs/swagger';
import { randomUUID } from 'crypto';
import { AgentService } from './agent.service';
import { TelemetryService } from '../shared/telemetry.service';
import { TenantId, ApiTenantQuery } from '../auth/tenant.decorator';
import { AgentQueryDto } from './agent-query.dto';

@ApiTags('agent')
@ApiBearerAuth()
@Controller('agent')
export class AgentController {
  private readonly logger = new Logger(AgentController.name);

  constructor(private readonly agentService: AgentService, private readonly tel: TelemetryService) {}

  @Post('run')
  @ApiTenantQuery()
  async agentRun(@Body() dto: AgentQueryDto, @TenantId() tenantId: string) {
    const runId = randomUUID();
    this.tel.record(tenantId, '/agent/run');
    return this.agentService.run(dto.query, tenantId, runId);
  }
}
