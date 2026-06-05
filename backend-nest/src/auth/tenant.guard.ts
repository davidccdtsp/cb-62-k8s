import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import { JwksService } from './jwks.service';

@Injectable()
export class TenantGuard implements CanActivate {
  constructor(private readonly jwks: JwksService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context.switchToHttp().getRequest();
    const authHeader: string | undefined = req.headers.authorization;
    const fallback = (req.query.tenant_id as string) || 'tenant-1';

    if (!authHeader?.startsWith('Bearer ')) {
      req.tenantId = fallback;
      return true;
    }

    const token = authHeader.split(' ')[1];
    try {
      const payload = await this.jwks.verify(token);
      req.tenantId = (payload?.['tenant_id'] as string) ?? fallback;
    } catch (err) {
      throw new UnauthorizedException(err.message);
    }
    return true;
  }
}
