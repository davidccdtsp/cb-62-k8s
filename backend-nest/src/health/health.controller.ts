import { Controller, Get } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

@ApiTags('ops')
@Controller('health')
export class HealthController {
  @Get()
  health() {
    return { status: 'ok' };
  }
}
