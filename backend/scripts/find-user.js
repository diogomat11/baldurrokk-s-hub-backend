require('dotenv').config({ path: require('path').resolve(__dirname, '..', '.env') });
const { supabase } = require('../src/supabase');

async function main() {
  const email = process.argv[2];
  if (!email) {
    console.error('Uso: node scripts/find-user.js <email>');
    process.exit(1);
  }
  try {
    const { data, error } = await supabase
      .from('users')
      .select('id,email,name,role,status')
      .eq('email', email)
      .limit(1)
      .maybeSingle();
    if (error) {
      console.error('Erro na consulta:', error.message);
      process.exit(1);
    }
    if (!data) {
      console.log('Usuário não encontrado');
      process.exit(2);
    }
    console.log('Usuário encontrado:', data);
  } catch (e) {
    console.error('Erro inesperado:', e?.message || e);
    process.exit(1);
  }
}

main();