import { Module } from '@nestjs/common';
import { JwksService } from './jwks.service';
import { TenantGuard } from './tenant.guard';

@Module({
  providers: [JwksService, TenantGuard],
  exports: [JwksService, TenantGuard],
})
export class AuthModule {}
