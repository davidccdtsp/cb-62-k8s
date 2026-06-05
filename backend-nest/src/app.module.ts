import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { SharedModule } from './shared/shared.module';
import { AuthModule } from './auth/auth.module';
import { TenantGuard } from './auth/tenant.guard';
import { HealthController } from './health/health.controller';
import { ProductsModule } from './products/products.module';
import { OrdersModule } from './orders/orders.module';
import { UsersModule } from './users/users.module';
import { AgentModule } from './agent/agent.module';

@Module({
  imports: [SharedModule, AuthModule, ProductsModule, OrdersModule, UsersModule, AgentModule],
  controllers: [HealthController],
  providers: [
    TenantGuard,
    { provide: APP_GUARD, useClass: TenantGuard },
  ],
})
export class AppModule {}
