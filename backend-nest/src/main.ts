import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { SwaggerModule, DocumentBuilder } from '@nestjs/swagger';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { logger: ['log', 'warn', 'error'] });

  const config = new DocumentBuilder()
    .setTitle('Demo Backend (NestJS)')
    .setDescription(
      'Servicio de demostración para observabilidad con OpenTelemetry + Grafana. ' +
      'Usa el botón Authorize para introducir un Bearer token obtenido de Keycloak.',
    )
    .setVersion('1.0.0')
    .addBearerAuth()
    .build();

  SwaggerModule.setup('docs', app, SwaggerModule.createDocument(app, config));

  await app.listen(3000, '0.0.0.0');
}

bootstrap();
