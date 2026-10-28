// Cloudflare Pages Function: atiende todas las peticiones a /api
import { manejar } from "../src/api-core.mjs";

export const onRequest = (context) => manejar(context.request, context.env);
