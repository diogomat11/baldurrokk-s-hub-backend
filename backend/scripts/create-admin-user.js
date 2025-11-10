require('dotenv').config({ path: require('path').resolve(__dirname, '..', '.env') });
const { supabase } = require('../src/supabase');

async function main() {
  const email = process.argv[2];
  const password = process.argv[3];
  const name = process.argv[4] || 'Admin';
  if (!email || !password) {
    console.error('Uso: node scripts/create-admin-user.js <email> <senha> [nome]');
    process.exit(1);
  }
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    console.error('Supabase não configurado (SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY)');
    process.exit(1);
  }
  try {
    const { data, error } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { name },
    });
    if (error) {
      console.error('Erro ao criar usuário:', error.message);
      process.exit(1);
    }
    const userId = data?.user?.id;
    if (!userId) {
      console.error('Usuário criado sem ID retornado.');
      process.exit(1);
    }
    // Inserir/atualizar na tabela users com role Admin
    const { error: upErr } = await supabase
      .from('users')
      .upsert({ id: userId, email, name, role: 'Admin', status: 'Ativo' }, { onConflict: 'id' });
    if (upErr) {
      console.error('Erro ao inserir/atualizar users:', upErr.message);
      process.exit(1);
    }
    console.log('Usuário Admin criado:', { id: userId, email, name });
  } catch (e) {
    console.error('Erro inesperado:', e?.message || e);
    process.exit(1);
  }
}

main();