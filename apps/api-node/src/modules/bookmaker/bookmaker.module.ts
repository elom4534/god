import { Module } from '@nestjs/common';
import { BookmakerController } from './bookmaker.controller';

@Module({ controllers: [BookmakerController] })
export class BookmakerModule {}
