import { Injectable, Logger, UnauthorizedException } from '@nestjs/common';
import { createRemoteJWKSet, jwtVerify, type JWTPayload } from 'jose';

@Injectable()
export class JwksService {
  private readonly logger = new Logger(JwksService.name);
  private readonly jwks: ReturnType<typeof createRemoteJWKSet> | null;
  private readonly audience: string;

  constructor() {
    const keycloakUrl = (process.env.KEYCLOAK_URL || '').replace(/\/$/, '');
    const realm = process.env.KEYCLOAK_REALM || 'poc';
    this.audience = process.env.KEYCLOAK_AUDIENCE || '';

    if (keycloakUrl) {
      const uri = `${keycloakUrl}/realms/${realm}/protocol/openid-connect/certs`;
      this.jwks = createRemoteJWKSet(new URL(uri));
    } else {
      this.jwks = null;
      this.logger.warn('KEYCLOAK_URL not set — JWT validation disabled');
    }
  }

  async verify(token: string): Promise<JWTPayload | null> {
    if (!this.jwks) return null;
    try {
      const { payload } = await jwtVerify(token, this.jwks, {
        algorithms: ['RS256'],
        ...(this.audience ? { audience: this.audience } : {}),
      });
      return payload;
    } catch (err) {
      throw new UnauthorizedException(err.message);
    }
  }
}
