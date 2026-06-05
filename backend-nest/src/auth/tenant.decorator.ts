import { createParamDecorator, ExecutionContext } from '@nestjs/common';
import { ApiQuery } from '@nestjs/swagger';

export const TenantId = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): string =>
    ctx.switchToHttp().getRequest().tenantId ?? 'tenant-1',
);

export const ApiTenantQuery = () =>
  ApiQuery({ name: 'tenant_id', required: false, description: 'Tenant (fallback sin JWT)', example: 'tenant-1' });
