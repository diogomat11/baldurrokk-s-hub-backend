
require('dotenv').config({ path: require('path').resolve(__dirname, 'backend', '.env') });
const { createClient } = require('@supabase/supabase-js');

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !supabaseKey) {
    console.error('Missing env vars');
    process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function run() {
    console.log('Checking units table...');

    // 1. Check if manager_ids column exists by selecting it
    const { data: selectData, error: selectError } = await supabase
        .from('units')
        .select('id, manager_ids')
        .limit(1);

    if (selectError) {
        console.error('Select Error (Column likely missing):', selectError.message);
    } else {
        console.log('Select manager_ids Success:', JSON.stringify(selectData, null, 2));
    }

    // 2. Intentionally try to update a fake ID to see if schema rejects the payload structure
    const { error: updateError } = await supabase
        .from('units')
        .update({
            repass_type: 'Percentual',
            repass_value: 35,
            manager_ids: []
        })
        .eq('id', '00000000-0000-0000-0000-000000000000'); // Fake ID

    if (updateError) {
        console.log('Update Error:', updateError.message);
    } else {
        console.log('Update simulated (no row found, but no schema error).');
    }
}

run();
