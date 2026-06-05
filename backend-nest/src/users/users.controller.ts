import { Controller, Get, Logger } from '@nestjs/common';
import { ApiTags, ApiBearerAuth } from '@nestjs/swagger';
import { DataService } from '../shared/data.service';
import { TelemetryService } from '../shared/telemetry.service';
import { TenantId, ApiTenantQuery } from '../auth/tenant.decorator';

const rand  = (min: number, max: number) => Math.random() * (max - min) + min;
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

@ApiTags('users')
@ApiBearerAuth()
@Controller('users')
export class UsersController {
  private readonly logger = new Logger(UsersController.name);

  constructor(private readonly data: DataService, private readonly tel: TelemetryService) {}

  @Get()
  @ApiTenantQuery()
  async listUsers(@TenantId() tenantId: string) {
    this.tel.record(tenantId, '/users');
    await sleep(rand(20, 120));
    this.logger.log(`listing users count=${this.data.users.length} tenant_id=${tenantId}`);
    return this.data.users;
  }
}
