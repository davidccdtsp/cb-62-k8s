import { Global, Module } from '@nestjs/common';
import { DataService } from './data.service';
import { TelemetryService } from './telemetry.service';

@Global()
@Module({
  providers: [DataService, TelemetryService],
  exports: [DataService, TelemetryService],
})
export class SharedModule {}
