import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { JwtAuthGuard } from './jwt-auth.guard';

@Module({
  imports: [JwtModule.register({ secret: process.env.JWT_SECRET || 'dev-secret', signOptions: { expiresIn: '15m' } })],
  controllers: [AuthController],
  providers: [AuthService, JwtAuthGuard],
  exports: [JwtModule, AuthService, JwtAuthGuard],
})
export class AuthModule {}
