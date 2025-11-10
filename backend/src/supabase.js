require('dotenv').config();
 const { createClient } = require('@supabase/supabase-js');

 const SUPABASE_URL = process.env.SUPABASE_URL;
 const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
 const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY;

 function notConfiguredError() {
   return { data: null, error: { message: 'supabase_not_configured' } };
 }

 // Resposta amigável para listas em modo dev: evitar 500 e retornar vazio
 function notConfiguredList() {
   return { data: [], error: null };
 }

 let supabase;
 if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
   console.warn('[supabase] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
   // Stub client robusta para ambiente de desenvolvimento sem Supabase
   const makeChain = () => {
     const chain = {
       select: () => chain,
       eq: () => chain,
       lt: () => chain,
       match: () => chain,
       in: () => chain,
       gte: () => chain,
       lte: () => chain,
       order: () => chain,
       ilike: () => chain,
       limit: () => chain,
       insert: () => chain,
       update: () => chain,
       single: () => chain,
       maybeSingle: () => chain,
       then: (resolve) => Promise.resolve(notConfiguredList()).then(resolve),
       catch: (reject) => Promise.resolve(notConfiguredList()).catch(reject),
     };
     return chain;
   };

   supabase = {
     // RPCs não quebram; retornam erro de não configurado
     rpc: async () => notConfiguredError(),
     from: () => makeChain(),
     auth: {
       admin: {
         createUser: async () => notConfiguredError(),
       },
     },
   };
 } else {
   supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
     auth: { persistSession: false },
   });
 }

 function createUserClient(token) {
   if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !token) {
     return null;
   }
   return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
     auth: { persistSession: false },
     global: { headers: { Authorization: `Bearer ${token}` } },
   });
 }

 module.exports = { supabase, createUserClient };