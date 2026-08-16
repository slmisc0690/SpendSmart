import { createClient } from '@supabase/supabase-js'

const url = 'https://wwxzjxncvvbdpaydibvd.supabase.co'
const key = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!key) {
  console.error('Missing SUPABASE_SERVICE_ROLE_KEY')
  process.exit(1)
}

const supabase = createClient(url, key, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
})

const { data, error } = await supabase.auth.admin.createUser({
  id: '00000000-0000-0000-0000-000000000001',
  email: 'plaid-sandbox-system@spendsmart.local',
  email_confirm: true,
  user_metadata: {
    purpose: 'plaid_sandbox_system_user',
  },
})

if (error) {
  console.error(`Creation failed: ${error.message}`)
  process.exit(1)
}

console.log(`Created Sandbox user: ${data.user?.id}`)
