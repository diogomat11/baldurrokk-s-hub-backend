

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."app_role" AS ENUM (
    'admin',
    'manager',
    'user'
);


ALTER TYPE "public"."app_role" OWNER TO "postgres";


COMMENT ON TYPE "public"."app_role" IS 'Roles de usuário do sistema';



CREATE TYPE "public"."categoria_aluno" AS ENUM (
    'infantil',
    'juvenil',
    'adulto',
    'master',
    'sub_6',
    'sub_8',
    'sub_10',
    'sub_12',
    'sub_14',
    'sub_16',
    'sub_18',
    'sub_20'
);


ALTER TYPE "public"."categoria_aluno" OWNER TO "postgres";


COMMENT ON TYPE "public"."categoria_aluno" IS 'Categorias de idade dos alunos (Sub-6 a Sub-20, Adulto, Master)';



CREATE TYPE "public"."dia_semana" AS ENUM (
    'segunda',
    'terca',
    'quarta',
    'quinta',
    'sexta',
    'sabado',
    'domingo'
);


ALTER TYPE "public"."dia_semana" OWNER TO "postgres";


COMMENT ON TYPE "public"."dia_semana" IS 'Dias da semana para horários';



CREATE TYPE "public"."forma_pagamento" AS ENUM (
    'dinheiro',
    'cartao_credito',
    'cartao_debito',
    'pix',
    'transferencia',
    'boleto',
    'cheque'
);


ALTER TYPE "public"."forma_pagamento" OWNER TO "postgres";


COMMENT ON TYPE "public"."forma_pagamento" IS 'Formas de pagamento disponíveis';



CREATE TYPE "public"."frequencia_treino" AS ENUM (
    '1x',
    '2x',
    '3x',
    '4x',
    '5x'
);


ALTER TYPE "public"."frequencia_treino" OWNER TO "postgres";


COMMENT ON TYPE "public"."frequencia_treino" IS 'Frequência semanal de treinos';



CREATE TYPE "public"."recorrencia_tipo" AS ENUM (
    'mensal',
    'trimestral',
    'semestral',
    'anual'
);


ALTER TYPE "public"."recorrencia_tipo" OWNER TO "postgres";


COMMENT ON TYPE "public"."recorrencia_tipo" IS 'Tipos de recorrência para planos';



CREATE TYPE "public"."status_pagamento" AS ENUM (
    'pendente',
    'pago',
    'atrasado',
    'cancelado'
);


ALTER TYPE "public"."status_pagamento" OWNER TO "postgres";


COMMENT ON TYPE "public"."status_pagamento" IS 'Status de pagamentos';



CREATE TYPE "public"."status_turma" AS ENUM (
    'ativa',
    'inativa',
    'suspensa',
    'finalizada'
);


ALTER TYPE "public"."status_turma" OWNER TO "postgres";


COMMENT ON TYPE "public"."status_turma" IS 'Status possíveis para turmas';



CREATE TYPE "public"."tipo_repasse" AS ENUM (
    'percentual',
    'valor_fixo'
);


ALTER TYPE "public"."tipo_repasse" OWNER TO "postgres";


COMMENT ON TYPE "public"."tipo_repasse" IS 'Tipos de repasse para unidades';



CREATE OR REPLACE FUNCTION "public"."atualizar_status_parcela"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    -- Atualizar status baseado na data de vencimento e pagamento
    IF NEW.data_pagamento IS NOT NULL THEN
        NEW.status = 'pago';
    ELSIF NEW.data_vencimento < CURRENT_DATE THEN
        NEW.status = 'atrasado';
    ELSE
        NEW.status = 'pendente';
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."atualizar_status_parcela"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calcular_desconto_proporcional"("data_inicio" "date") RETURNS numeric
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    dias_no_mes integer;
    dias_restantes integer;
    percentual_desconto numeric;
BEGIN
    -- Calcular dias no mês
    dias_no_mes := EXTRACT(DAY FROM (date_trunc('month', data_inicio) + interval '1 month - 1 day')::date);
    
    -- Calcular dias restantes no mês
    dias_restantes := dias_no_mes - EXTRACT(DAY FROM data_inicio) + 1;
    
    -- Calcular percentual proporcional
    percentual_desconto := (dias_restantes::numeric / dias_no_mes::numeric) * 100;
    
    -- Buscar na tabela de proporcionalidade se existe regra específica
    SELECT p.percentual INTO percentual_desconto
    FROM proporcionalidade p
    WHERE dias_restantes >= p.dias_inicio 
    AND dias_restantes <= p.dias_fim
    AND p.ativo = true
    LIMIT 1;
    
    RETURN COALESCE(percentual_desconto, 0);
END;
$$;


ALTER FUNCTION "public"."calcular_desconto_proporcional"("data_inicio" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calcular_idade"("data_nascimento" "date") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    IF data_nascimento IS NULL THEN
        RETURN NULL;
    END IF;
    
    RETURN EXTRACT(YEAR FROM AGE(CURRENT_DATE, data_nascimento));
END;
$$;


ALTER FUNCTION "public"."calcular_idade"("data_nascimento" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."calcular_idade"("data_nascimento" "date") IS 'Calcula idade baseada na data de nascimento';



CREATE OR REPLACE FUNCTION "public"."calcular_valor_com_desconto"("valor_original" numeric, "percentual_desconto" numeric DEFAULT 0) RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    IF valor_original IS NULL OR valor_original <= 0 THEN
        RETURN 0;
    END IF;
    
    IF percentual_desconto IS NULL OR percentual_desconto <= 0 THEN
        RETURN valor_original;
    END IF;
    
    RETURN ROUND(valor_original * (1 - percentual_desconto / 100), 2);
END;
$$;


ALTER FUNCTION "public"."calcular_valor_com_desconto"("valor_original" numeric, "percentual_desconto" numeric) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."calcular_valor_com_desconto"("valor_original" numeric, "percentual_desconto" numeric) IS 'Calcula valor final com desconto aplicado';



CREATE OR REPLACE FUNCTION "public"."calcular_valor_transferencia"("p_valor_base" numeric, "p_tipo_repasse" "text", "p_valor_repasse" numeric, "p_percentual_repasse" numeric) RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    IF p_tipo_repasse = 'fixo' AND p_valor_repasse IS NOT NULL THEN
        RETURN p_valor_repasse;
    ELSIF p_tipo_repasse = 'percentual' AND p_percentual_repasse IS NOT NULL THEN
        RETURN ROUND(p_valor_base * (p_percentual_repasse / 100), 2);
    ELSE
        RETURN 0;
    END IF;
END;
$$;


ALTER FUNCTION "public"."calcular_valor_transferencia"("p_valor_base" numeric, "p_tipo_repasse" "text", "p_valor_repasse" numeric, "p_percentual_repasse" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."determinar_categoria"("data_nascimento" "date") RETURNS "public"."categoria_aluno"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    idade INTEGER;
BEGIN
    -- Calcular idade em anos
    idade := EXTRACT(YEAR FROM AGE(CURRENT_DATE, data_nascimento));
    
    -- Determinar categoria baseada na idade
    CASE 
        WHEN idade <= 6 THEN RETURN 'sub_6'::public.categoria_aluno;
        WHEN idade <= 8 THEN RETURN 'sub_8'::public.categoria_aluno;
        WHEN idade <= 10 THEN RETURN 'sub_10'::public.categoria_aluno;
        WHEN idade <= 12 THEN RETURN 'sub_12'::public.categoria_aluno;
        WHEN idade <= 14 THEN RETURN 'sub_14'::public.categoria_aluno;
        WHEN idade <= 16 THEN RETURN 'sub_16'::public.categoria_aluno;
        WHEN idade <= 18 THEN RETURN 'sub_18'::public.categoria_aluno;
        WHEN idade <= 20 THEN RETURN 'sub_20'::public.categoria_aluno;
        WHEN idade <= 15 THEN RETURN 'sub15'::public.categoria_aluno;
    ELSE RETURN 'sub17'::public.categoria_aluno;
    END CASE;
END;
$$;


ALTER FUNCTION "public"."determinar_categoria"("data_nascimento" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."determinar_categoria"("data_nascimento" "date") IS 'Determina categoria do aluno pela idade (Sub-6 a Sub-20, Adulto, Master)';



CREATE OR REPLACE FUNCTION "public"."gerar_parcelas_aluno"("p_aluno_id" "uuid", "p_plano_id" "uuid", "p_data_inicio" "date" DEFAULT CURRENT_DATE, "p_numero_parcelas" integer DEFAULT NULL::integer, "p_aplicar_proporcionalidade" boolean DEFAULT false) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_aluno_nome text;
    v_plano_nome text;
    v_plano_valor numeric;
    v_aluno_tipo_pagamento_id uuid;
    v_data_vencimento date;
    v_parcelas_criadas integer := 0;
    v_numero_parcelas integer;
    v_valor_parcela numeric;
    v_desconto_proporcional numeric := 0;
BEGIN
    -- Buscar dados do aluno
    SELECT nome, tipo_pagamento_id INTO v_aluno_nome, v_aluno_tipo_pagamento_id
    FROM public.alunos 
    WHERE id = p_aluno_id AND status = 'ativo';
    
    IF v_aluno_nome IS NULL THEN
        RETURN 'Erro: Aluno não encontrado ou inativo';
    END IF;
    
    -- Buscar dados do plano
    SELECT 
        COALESCE(nome, 'Plano Padrão') as nome, 
        valor 
    INTO v_plano_nome, v_plano_valor
    FROM public.planos 
    WHERE id = p_plano_id AND ativo = true;
    
    IF v_plano_nome IS NULL OR v_plano_valor IS NULL THEN
        RETURN 'Erro: Plano não encontrado ou inativo';
    END IF;
    
    -- Definir tipo de pagamento padrão se não especificado
    IF v_aluno_tipo_pagamento_id IS NULL THEN
        SELECT id INTO v_aluno_tipo_pagamento_id 
        FROM public.tipos_pagamento 
        WHERE codigo = 'PIX' AND ativo = true 
        LIMIT 1;
        
        -- Se ainda não encontrou, usar o primeiro tipo ativo
        IF v_aluno_tipo_pagamento_id IS NULL THEN
            SELECT id INTO v_aluno_tipo_pagamento_id 
            FROM public.tipos_pagamento 
            WHERE ativo = true 
            LIMIT 1;
        END IF;
    END IF;
    
    -- Definir número de parcelas (padrão: 12 para mensal)
    v_numero_parcelas := COALESCE(p_numero_parcelas, 12);
    
    -- Aplicar desconto proporcional se solicitado
    IF p_aplicar_proporcionalidade THEN
        v_desconto_proporcional := public.calcular_desconto_proporcional(p_data_inicio);
    END IF;
    
    -- Calcular valor da parcela com desconto
    v_valor_parcela := v_plano_valor * (1 - v_desconto_proporcional / 100);
    
    -- Gerar parcelas
    v_data_vencimento := p_data_inicio;
    
    FOR i IN 1..v_numero_parcelas LOOP
        INSERT INTO public.parcelas (
            aluno_id,
            plano_id,
            numero_parcela,
            valor_original,
            valor_desconto,
            valor_final,
            valor,
            data_vencimento,
            tipo_pagamento_id,
            status
        ) VALUES (
            p_aluno_id,
            p_plano_id,
            i,
            v_plano_valor,
            v_plano_valor - v_valor_parcela,
            v_valor_parcela,
            v_valor_parcela,
            v_data_vencimento,
            v_aluno_tipo_pagamento_id,
            'pendente'
        );
        
        v_parcelas_criadas := v_parcelas_criadas + 1;
        
        -- Próximo mês
        v_data_vencimento := v_data_vencimento + INTERVAL '1 month';
    END LOOP;
    
    RETURN format('Sucesso: %s parcelas criadas para %s (%s)', 
                 v_parcelas_criadas, v_aluno_nome, v_plano_nome);
END;
$$;


ALTER FUNCTION "public"."gerar_parcelas_aluno"("p_aluno_id" "uuid", "p_plano_id" "uuid", "p_data_inicio" "date", "p_numero_parcelas" integer, "p_aplicar_proporcionalidade" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gerar_proximo_vencimento"("data_base" "date", "tipo_recorrencia" "public"."recorrencia_tipo") RETURNS "date"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    CASE tipo_recorrencia
        WHEN 'mensal' THEN
            RETURN data_base + INTERVAL '1 month';
        WHEN 'trimestral' THEN
            RETURN data_base + INTERVAL '3 months';
        WHEN 'semestral' THEN
            RETURN data_base + INTERVAL '6 months';
        WHEN 'anual' THEN
            RETURN data_base + INTERVAL '1 year';
        ELSE
            RETURN data_base + INTERVAL '1 month';
    END CASE;
END;
$$;


ALTER FUNCTION "public"."gerar_proximo_vencimento"("data_base" "date", "tipo_recorrencia" "public"."recorrencia_tipo") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."gerar_proximo_vencimento"("data_base" "date", "tipo_recorrencia" "public"."recorrencia_tipo") IS 'Gera próxima data de vencimento baseada na recorrência';



CREATE OR REPLACE FUNCTION "public"."get_user_unidade_id"() RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN (
        SELECT unidade_id FROM public.profiles 
        WHERE id = auth.uid() 
        AND ativo = true
    );
END;
$$;


ALTER FUNCTION "public"."get_user_unidade_id"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_user_unidade_id"() IS 'Retorna a unidade_id do usuário atual';



CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    INSERT INTO public.profiles (id, nome, email, role)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data->>'nome', NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
        NEW.email,
        'user'
    );
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_updated_at"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."handle_updated_at"() IS 'Função para atualizar automaticamente o campo updated_at em triggers';



CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.profiles 
        WHERE id = auth.uid() 
        AND role = 'admin' 
        AND ativo = true
    );
END;
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."is_admin"() IS 'Verifica se o usuário atual é admin';



CREATE OR REPLACE FUNCTION "public"."is_manager"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.profiles 
        WHERE id = auth.uid() 
        AND role IN ('admin', 'manager') 
        AND ativo = true
    );
END;
$$;


ALTER FUNCTION "public"."is_manager"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."is_manager"() IS 'Verifica se o usuário atual é manager ou admin';



CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
    begin
      new.updated_at := now();
      return new;
    end;
    $$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_atualizar_categoria_aluno"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.data_nascimento IS NOT NULL THEN
        NEW.categoria := public.determinar_categoria(NEW.data_nascimento);
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_atualizar_categoria_aluno"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."alunos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" character varying(255) NOT NULL,
    "data_nascimento" "date",
    "cpf" character varying(14),
    "rg" character varying(20),
    "endereco" "text",
    "telefone" character varying(20),
    "email" character varying(255),
    "nome_responsavel" character varying(255),
    "telefone_responsavel" character varying(20),
    "email_responsavel" character varying(255),
    "unidade_id" "uuid" NOT NULL,
    "plano_id" "uuid",
    "categoria" "public"."categoria_aluno",
    "turma_id" "uuid",
    "recorrencia_id" "uuid",
    "tipo_pagamento_id" "uuid",
    "data_matricula" "date" DEFAULT CURRENT_DATE,
    "data_cancelamento" "date",
    "ativo" boolean DEFAULT true,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "status" "text" DEFAULT 'ativo'::"text",
    "data_inicio" "date",
    "cidade" character varying(255),
    "estado" character varying(2),
    "cep" character varying(10),
    "cpf_responsavel" character varying(14),
    "data_saida" "date",
    CONSTRAINT "alunos_status_check" CHECK (("status" = ANY (ARRAY['ativo'::"text", 'inativo'::"text", 'suspenso'::"text", 'cancelado'::"text"])))
);


ALTER TABLE "public"."alunos" OWNER TO "postgres";


COMMENT ON TABLE "public"."alunos" IS 'Alunos matriculados na escola';



COMMENT ON COLUMN "public"."alunos"."status" IS 'Status atual do aluno: ativo, inativo, suspenso, cancelado';



CREATE TABLE IF NOT EXISTS "public"."planos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" character varying(255) NOT NULL,
    "unidade_id" "uuid" NOT NULL,
    "frequencia_treino" "public"."frequencia_treino" NOT NULL,
    "valor" numeric(10,2) NOT NULL,
    "data_inicio" "date" NOT NULL,
    "data_fim" "date",
    "ativo" boolean DEFAULT true,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "check_planos_valor_positivo" CHECK (("valor" > (0)::numeric))
);


ALTER TABLE "public"."planos" OWNER TO "postgres";


COMMENT ON TABLE "public"."planos" IS 'Planos de treino oferecidos pelas unidades';



CREATE TABLE IF NOT EXISTS "public"."recorrencias" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" character varying(255) NOT NULL,
    "tipo" "public"."recorrencia_tipo" NOT NULL,
    "percentual_desconto" numeric(5,2) DEFAULT 0.00,
    "data_inicio" "date" NOT NULL,
    "data_fim" "date",
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."recorrencias" OWNER TO "postgres";


COMMENT ON TABLE "public"."recorrencias" IS 'Recorrências de pagamento com descontos';



CREATE TABLE IF NOT EXISTS "public"."tipos_pagamento" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" character varying(100) NOT NULL,
    "recorrencia_tipo" "public"."forma_pagamento" NOT NULL,
    "taxa_processamento" numeric(5,2) DEFAULT 0.00,
    "prazo_compensacao" integer DEFAULT 0,
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tipos_pagamento" OWNER TO "postgres";


COMMENT ON TABLE "public"."tipos_pagamento" IS 'Tipos de pagamento disponíveis';



CREATE TABLE IF NOT EXISTS "public"."turmas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" character varying(255) NOT NULL,
    "categoria" "public"."categoria_aluno",
    "unidade_id" "uuid" NOT NULL,
    "professor_id" "uuid",
    "horario_inicio" time without time zone,
    "horario_fim" time without time zone,
    "dias_semana" "public"."dia_semana"[] DEFAULT '{}'::"public"."dia_semana"[],
    "status" "public"."status_turma" DEFAULT 'ativa'::"public"."status_turma",
    "vagas" integer DEFAULT 0,
    "valor" numeric(10,2),
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."turmas" OWNER TO "postgres";


COMMENT ON TABLE "public"."turmas" IS 'Turmas de treino organizadas por categoria e horário';



CREATE TABLE IF NOT EXISTS "public"."unidades" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" character varying(255) NOT NULL,
    "endereco" "text",
    "cidade" character varying(100),
    "estado" character varying(2),
    "cep" character varying(10),
    "telefone" character varying(20),
    "email" character varying(255),
    "responsavel" character varying(255),
    "percentual_repasse" numeric(5,2) DEFAULT 0.00,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "ativo" boolean DEFAULT true
);


ALTER TABLE "public"."unidades" OWNER TO "postgres";


COMMENT ON TABLE "public"."unidades" IS 'Unidades/filiais da escola de futebol';



COMMENT ON COLUMN "public"."unidades"."ativo" IS 'Indica se a unidade está ativa no sistema';



CREATE OR REPLACE VIEW "public"."alunos_completos" AS
 SELECT "a"."id",
    "a"."nome",
    "a"."data_nascimento",
    "a"."cpf",
    "a"."rg",
    "a"."endereco",
    "a"."telefone",
    "a"."email",
    "a"."nome_responsavel",
    "a"."telefone_responsavel",
    "a"."email_responsavel",
    "a"."unidade_id",
    "u"."nome" AS "unidade_nome",
    "a"."plano_id",
    "p"."nome" AS "plano_nome",
    "p"."valor" AS "plano_valor",
    "a"."categoria",
    "a"."turma_id",
    "t"."nome" AS "turma_nome",
    "a"."recorrencia_id",
    "r"."nome" AS "recorrencia_nome",
    "r"."percentual_desconto" AS "recorrencia_desconto",
    "a"."tipo_pagamento_id",
    "tp"."nome" AS "tipo_pagamento_nome",
    "a"."data_matricula",
    "a"."data_cancelamento",
    "a"."ativo",
    "a"."observacoes",
    "a"."created_at",
    "a"."updated_at"
   FROM ((((("public"."alunos" "a"
     LEFT JOIN "public"."unidades" "u" ON (("a"."unidade_id" = "u"."id")))
     LEFT JOIN "public"."planos" "p" ON (("a"."plano_id" = "p"."id")))
     LEFT JOIN "public"."turmas" "t" ON (("a"."turma_id" = "t"."id")))
     LEFT JOIN "public"."recorrencias" "r" ON (("a"."recorrencia_id" = "r"."id")))
     LEFT JOIN "public"."tipos_pagamento" "tp" ON (("a"."tipo_pagamento_id" = "tp"."id")));


ALTER VIEW "public"."alunos_completos" OWNER TO "postgres";


COMMENT ON VIEW "public"."alunos_completos" IS 'View com informações completas dos alunos';



CREATE TABLE IF NOT EXISTS "public"."alunos_descontos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "desconto_id" "uuid" NOT NULL,
    "data_aplicacao" "date" DEFAULT CURRENT_DATE,
    "data_expiracao" "date",
    "ativo" boolean DEFAULT true,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."alunos_descontos" OWNER TO "postgres";


COMMENT ON TABLE "public"."alunos_descontos" IS 'Descontos aplicados aos alunos';



CREATE TABLE IF NOT EXISTS "public"."alunos_turmas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "turma_id" "uuid" NOT NULL,
    "data_inicio" "date" DEFAULT CURRENT_DATE,
    "data_fim" "date",
    "ativo" boolean DEFAULT true,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."alunos_turmas" OWNER TO "postgres";


COMMENT ON TABLE "public"."alunos_turmas" IS 'Histórico de turmas dos alunos';



CREATE TABLE IF NOT EXISTS "public"."comprovantes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "parcela_id" "uuid" NOT NULL,
    "arquivo_url" "text" NOT NULL,
    "nome_arquivo" "text" NOT NULL,
    "tipo_arquivo" "text",
    "tamanho_arquivo" integer,
    "data_upload" timestamp with time zone DEFAULT "now"(),
    "uploaded_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."comprovantes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."descontos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" character varying(255) NOT NULL,
    "valor" numeric(10,2),
    "percentual" numeric(5,2),
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "tipo" "text" DEFAULT 'geral'::"text",
    CONSTRAINT "check_desconto_valor_ou_percentual" CHECK (((("valor" IS NOT NULL) AND ("percentual" IS NULL)) OR (("valor" IS NULL) AND ("percentual" IS NOT NULL)))),
    CONSTRAINT "descontos_tipo_check" CHECK (("tipo" = ANY (ARRAY['geral'::"text", 'familia'::"text", 'funcionario'::"text", 'estudante'::"text", 'aniversario'::"text", 'promocional'::"text"])))
);


ALTER TABLE "public"."descontos" OWNER TO "postgres";


COMMENT ON TABLE "public"."descontos" IS 'Descontos aplicáveis';



COMMENT ON COLUMN "public"."descontos"."tipo" IS 'Tipo de desconto: geral, familia, funcionario, estudante, aniversario, promocional';



CREATE TABLE IF NOT EXISTS "public"."despesas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "text" NOT NULL,
    "descricao" "text" NOT NULL,
    "valor" numeric(10,2) NOT NULL,
    "unidade_id" "uuid",
    "equipe_id" "uuid",
    "data_vencimento" "date",
    "data_pagamento" "date",
    "comprovante_url" "text",
    "observacoes" "text",
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "check_despesas_valor_positivo" CHECK (("valor" > (0)::numeric)),
    CONSTRAINT "despesas_tipo_check" CHECK (("tipo" = ANY (ARRAY['adiantamento'::"text", 'recorrente'::"text", 'pontual'::"text"])))
);


ALTER TABLE "public"."despesas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."equipe_tecnica" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" character varying(255) NOT NULL,
    "email" character varying(255),
    "telefone" character varying(20),
    "cpf" character varying(14),
    "cargo" character varying(100),
    "unidade_id" "uuid",
    "salario" numeric(10,2),
    "data_admissao" "date",
    "data_demissao" "date",
    "ativo" boolean DEFAULT true,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "especialidade" "text",
    "data_contratacao" "date",
    "status" "text" DEFAULT 'ativo'::"text",
    CONSTRAINT "equipe_tecnica_status_check" CHECK (("status" = ANY (ARRAY['ativo'::"text", 'inativo'::"text", 'afastado'::"text"])))
);


ALTER TABLE "public"."equipe_tecnica" OWNER TO "postgres";


COMMENT ON TABLE "public"."equipe_tecnica" IS 'Professores, coordenadores e demais funcionários';



CREATE TABLE IF NOT EXISTS "public"."equipe_unidades" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "equipe_id" "uuid" NOT NULL,
    "unidade_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."equipe_unidades" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."frequencia" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "turma_id" "uuid" NOT NULL,
    "data_aula" "date" NOT NULL,
    "presente" boolean DEFAULT false,
    "justificativa" "text",
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."frequencia" OWNER TO "postgres";


COMMENT ON TABLE "public"."frequencia" IS 'Controle de presença dos alunos nas aulas';



CREATE TABLE IF NOT EXISTS "public"."migration_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "migration_name" "text" NOT NULL,
    "executed_at" timestamp with time zone DEFAULT "now"(),
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."migration_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."migration_log" IS 'Tabela para rastrear execução de migrações';



COMMENT ON COLUMN "public"."migration_log"."migration_name" IS 'Nome único da migração executada';



COMMENT ON COLUMN "public"."migration_log"."executed_at" IS 'Data e hora da execução da migração';



COMMENT ON COLUMN "public"."migration_log"."description" IS 'Descrição do que a migração faz';



CREATE TABLE IF NOT EXISTS "public"."negociacoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "text" NOT NULL,
    "unidade_id" "uuid",
    "equipe_id" "uuid",
    "aluno_id" "uuid",
    "plano_id" "uuid",
    "desconto_id" "uuid",
    "tipo_repasse_negociacao" "text",
    "valor_repasse" numeric(10,2),
    "percentual_repasse" numeric(5,2),
    "data_inicio" "date" NOT NULL,
    "data_fim" "date",
    "motivo" "text",
    "condicoes_pagamento" "text",
    "observacoes" "text",
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "negociacoes_tipo_check" CHECK (("tipo" = ANY (ARRAY['unidade'::"text", 'equipe'::"text", 'aluno'::"text"]))),
    CONSTRAINT "negociacoes_tipo_repasse_negociacao_check" CHECK (("tipo_repasse_negociacao" = ANY (ARRAY['fixo'::"text", 'percentual'::"text"])))
);


ALTER TABLE "public"."negociacoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pagamentos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "plano_id" "uuid",
    "tipo_pagamento_id" "uuid",
    "valor_original" numeric(10,2) NOT NULL,
    "valor_desconto" numeric(10,2) DEFAULT 0.00,
    "valor_final" numeric(10,2) NOT NULL,
    "data_vencimento" "date" NOT NULL,
    "data_pagamento" "date",
    "status" "public"."status_pagamento" DEFAULT 'pendente'::"public"."status_pagamento",
    "mes_referencia" integer NOT NULL,
    "ano_referencia" integer NOT NULL,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "check_ano_referencia" CHECK (("ano_referencia" >= 2020)),
    CONSTRAINT "check_mes_referencia" CHECK ((("mes_referencia" >= 1) AND ("mes_referencia" <= 12))),
    CONSTRAINT "check_valores_positivos" CHECK ((("valor_original" >= (0)::numeric) AND ("valor_desconto" >= (0)::numeric) AND ("valor_final" >= (0)::numeric)))
);


ALTER TABLE "public"."pagamentos" OWNER TO "postgres";


COMMENT ON TABLE "public"."pagamentos" IS 'Controle de pagamentos dos alunos';



CREATE OR REPLACE VIEW "public"."pagamentos_completos" AS
 SELECT "p"."id",
    "p"."aluno_id",
    "a"."nome" AS "aluno_nome",
    "a"."unidade_id",
    "u"."nome" AS "unidade_nome",
    "p"."plano_id",
    "pl"."nome" AS "plano_nome",
    "p"."tipo_pagamento_id",
    "tp"."nome" AS "tipo_pagamento_nome",
    "p"."valor_original",
    "p"."valor_desconto",
    "p"."valor_final",
    "p"."data_vencimento",
    "p"."data_pagamento",
    "p"."status",
    "p"."mes_referencia",
    "p"."ano_referencia",
    "p"."observacoes",
    "p"."created_at",
    "p"."updated_at"
   FROM (((("public"."pagamentos" "p"
     LEFT JOIN "public"."alunos" "a" ON (("p"."aluno_id" = "a"."id")))
     LEFT JOIN "public"."unidades" "u" ON (("a"."unidade_id" = "u"."id")))
     LEFT JOIN "public"."planos" "pl" ON (("p"."plano_id" = "pl"."id")))
     LEFT JOIN "public"."tipos_pagamento" "tp" ON (("p"."tipo_pagamento_id" = "tp"."id")));


ALTER VIEW "public"."pagamentos_completos" OWNER TO "postgres";


COMMENT ON VIEW "public"."pagamentos_completos" IS 'View com informações completas dos pagamentos';



CREATE TABLE IF NOT EXISTS "public"."pagamentos_descontos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pagamento_id" "uuid" NOT NULL,
    "desconto_id" "uuid",
    "valor_desconto" numeric(10,2) DEFAULT 0.00 NOT NULL,
    "percentual_aplicado" numeric(5,2),
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."pagamentos_descontos" OWNER TO "postgres";


COMMENT ON TABLE "public"."pagamentos_descontos" IS 'Descontos aplicados nos pagamentos';



CREATE TABLE IF NOT EXISTS "public"."parcelas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "plano_id" "uuid" NOT NULL,
    "tipo_pagamento_id" "uuid",
    "valor_original" numeric(10,2) NOT NULL,
    "valor_desconto" numeric(10,2) DEFAULT 0,
    "valor_final" numeric(10,2) NOT NULL,
    "data_vencimento" "date" NOT NULL,
    "data_pagamento" "date",
    "status" "text" DEFAULT 'pendente'::"text",
    "mes_referencia" integer NOT NULL,
    "ano_referencia" integer NOT NULL,
    "comprovante_url" "text",
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "check_parcelas_desconto_valido" CHECK ((("valor_desconto" >= (0)::numeric) AND ("valor_desconto" <= "valor_original"))),
    CONSTRAINT "check_parcelas_mes_valido" CHECK ((("mes_referencia" >= 1) AND ("mes_referencia" <= 12))),
    CONSTRAINT "check_parcelas_valores_positivos" CHECK ((("valor_original" > (0)::numeric) AND ("valor_final" > (0)::numeric))),
    CONSTRAINT "parcelas_mes_referencia_check" CHECK ((("mes_referencia" >= 1) AND ("mes_referencia" <= 12))),
    CONSTRAINT "parcelas_status_check" CHECK (("status" = ANY (ARRAY['pendente'::"text", 'pago'::"text", 'vencido'::"text", 'cancelado'::"text"])))
);


ALTER TABLE "public"."parcelas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."planos_descontos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plano_id" "uuid" NOT NULL,
    "desconto_id" "uuid" NOT NULL,
    "data_inicio" "date" DEFAULT CURRENT_DATE,
    "data_fim" "date",
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."planos_descontos" OWNER TO "postgres";


COMMENT ON TABLE "public"."planos_descontos" IS 'Descontos aplicáveis aos planos';



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "nome" character varying(255),
    "email" character varying(255),
    "role" "public"."app_role" DEFAULT 'user'::"public"."app_role",
    "unidade_id" "uuid",
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON TABLE "public"."profiles" IS 'Perfis de usuários do sistema';



CREATE TABLE IF NOT EXISTS "public"."proporcionalidade" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dias_inicio" integer NOT NULL,
    "dias_fim" integer NOT NULL,
    "percentual" numeric(5,2) NOT NULL,
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "check_dias_validos" CHECK ((("dias_inicio" >= 1) AND ("dias_fim" <= 31) AND ("dias_inicio" <= "dias_fim")))
);


ALTER TABLE "public"."proporcionalidade" OWNER TO "postgres";


COMMENT ON TABLE "public"."proporcionalidade" IS 'Descontos proporcionais por dias do mês';



CREATE TABLE IF NOT EXISTS "public"."recorrencias_unidades" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recorrencia_id" "uuid" NOT NULL,
    "unidade_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."recorrencias_unidades" OWNER TO "postgres";


COMMENT ON TABLE "public"."recorrencias_unidades" IS 'Relacionamento entre recorrências e unidades';



CREATE TABLE IF NOT EXISTS "public"."repasses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "unidade_id" "uuid",
    "mes" integer NOT NULL,
    "ano" integer NOT NULL,
    "receita_total" numeric(12,2) DEFAULT 0.00,
    "percentual_repasse" numeric(5,2) DEFAULT 0.00,
    "valor_repasse" numeric(12,2) DEFAULT 0.00,
    "status" "public"."status_pagamento" DEFAULT 'pendente'::"public"."status_pagamento",
    "data_pagamento" "date",
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "check_ano_valido" CHECK (("ano" >= 2020)),
    CONSTRAINT "check_mes_valido" CHECK ((("mes" >= 1) AND ("mes" <= 12)))
);


ALTER TABLE "public"."repasses" OWNER TO "postgres";


COMMENT ON TABLE "public"."repasses" IS 'Controle de repasses para unidades';



CREATE TABLE IF NOT EXISTS "public"."transacoes_financeiras" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "text" NOT NULL,
    "categoria" "text" NOT NULL,
    "descricao" "text" NOT NULL,
    "valor" numeric(10,2) NOT NULL,
    "data_transacao" "date" NOT NULL,
    "unidade_id" "uuid",
    "aluno_id" "uuid",
    "parcela_id" "uuid",
    "comprovante_url" "text",
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "transacoes_financeiras_tipo_check" CHECK (("tipo" = ANY (ARRAY['entrada'::"text", 'saida'::"text"])))
);


ALTER TABLE "public"."transacoes_financeiras" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."turma_horarios" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "turma_id" "uuid" NOT NULL,
    "dia_semana" "public"."dia_semana" NOT NULL,
    "horario_inicio" time without time zone NOT NULL,
    "horario_fim" time without time zone NOT NULL,
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."turma_horarios" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."turma_professores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "turma_id" "uuid" NOT NULL,
    "professor_id" "uuid" NOT NULL,
    "ativo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."turma_professores" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."turmas_completas" AS
 SELECT "t"."id",
    "t"."nome",
    "t"."categoria",
    "t"."unidade_id",
    "u"."nome" AS "unidade_nome",
    "t"."professor_id",
    "et"."nome" AS "professor_nome",
    "t"."horario_inicio",
    "t"."horario_fim",
        CASE
            WHEN (("t"."horario_inicio" IS NOT NULL) AND ("t"."horario_fim" IS NOT NULL)) THEN ((("t"."horario_inicio")::"text" || ' - '::"text") || ("t"."horario_fim")::"text")
            ELSE NULL::"text"
        END AS "horario",
    "t"."dias_semana",
    "t"."status",
    "t"."vagas",
    "t"."valor",
    COALESCE("alunos_count"."total", (0)::bigint) AS "alunos_matriculados",
    "t"."observacoes",
    "t"."created_at",
    "t"."updated_at",
    COALESCE("array_agg"(DISTINCT ((((("th"."dia_semana")::"text" || ': '::"text") || ("th"."horario_inicio")::"text") || '-'::"text") || ("th"."horario_fim")::"text") ORDER BY ((((("th"."dia_semana")::"text" || ': '::"text") || ("th"."horario_inicio")::"text") || '-'::"text") || ("th"."horario_fim")::"text")) FILTER (WHERE (("th"."id" IS NOT NULL) AND ("th"."ativo" = true))), '{}'::"text"[]) AS "horarios_especificos",
    COALESCE("array_agg"(DISTINCT "et2"."nome" ORDER BY "et2"."nome") FILTER (WHERE (("et2"."id" IS NOT NULL) AND ("tp"."ativo" = true))), '{}'::character varying[]) AS "professores_nomes"
   FROM (((((("public"."turmas" "t"
     LEFT JOIN "public"."unidades" "u" ON (("t"."unidade_id" = "u"."id")))
     LEFT JOIN "public"."equipe_tecnica" "et" ON (("t"."professor_id" = "et"."id")))
     LEFT JOIN "public"."turma_horarios" "th" ON (("t"."id" = "th"."turma_id")))
     LEFT JOIN "public"."turma_professores" "tp" ON (("t"."id" = "tp"."turma_id")))
     LEFT JOIN "public"."equipe_tecnica" "et2" ON (("tp"."professor_id" = "et2"."id")))
     LEFT JOIN ( SELECT "alunos"."turma_id",
            "count"(*) AS "total"
           FROM "public"."alunos"
          WHERE ("alunos"."ativo" = true)
          GROUP BY "alunos"."turma_id") "alunos_count" ON (("t"."id" = "alunos_count"."turma_id")))
  GROUP BY "t"."id", "t"."nome", "t"."categoria", "t"."unidade_id", "u"."nome", "t"."professor_id", "et"."nome", "t"."horario_inicio", "t"."horario_fim", "t"."dias_semana", "t"."status", "t"."vagas", "t"."valor", "alunos_count"."total", "t"."observacoes", "t"."created_at", "t"."updated_at";


ALTER VIEW "public"."turmas_completas" OWNER TO "postgres";


COMMENT ON VIEW "public"."turmas_completas" IS 'View com informações completas das turmas';



CREATE TABLE IF NOT EXISTS "public"."turmas_professores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "turma_id" "uuid" NOT NULL,
    "professor_id" "uuid" NOT NULL,
    "principal" boolean DEFAULT false,
    "data_inicio" "date" DEFAULT CURRENT_DATE,
    "data_fim" "date",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."turmas_professores" OWNER TO "postgres";


COMMENT ON TABLE "public"."turmas_professores" IS 'Relacionamento entre turmas e professores';



CREATE OR REPLACE VIEW "public"."view_parcelas_completas" AS
 SELECT "p"."id",
    "p"."aluno_id",
    "a"."nome" AS "aluno_nome",
    "a"."nome_responsavel" AS "responsavel_nome",
    "a"."telefone_responsavel",
    "a"."email_responsavel",
    "p"."plano_id",
    "pl"."nome" AS "plano_nome",
    "pl"."valor" AS "plano_valor",
    "p"."tipo_pagamento_id",
    "tp"."nome" AS "tipo_pagamento_nome",
    "p"."valor_original",
    "p"."valor_desconto",
    "p"."valor_final",
    "p"."data_vencimento",
    "p"."data_pagamento",
    "p"."ano_referencia",
    "p"."mes_referencia",
    "p"."status",
    "p"."observacoes",
    "p"."comprovante_url",
    "p"."created_at",
    "p"."updated_at",
    "u"."nome" AS "unidade_nome",
        CASE
            WHEN ("p"."data_pagamento" IS NOT NULL) THEN 'pago'::"text"
            WHEN ("p"."data_vencimento" < CURRENT_DATE) THEN 'atrasado'::"text"
            ELSE 'pendente'::"text"
        END AS "status_calculado",
        CASE
            WHEN (("p"."data_vencimento" < CURRENT_DATE) AND ("p"."data_pagamento" IS NULL)) THEN (CURRENT_DATE - "p"."data_vencimento")
            ELSE 0
        END AS "dias_atraso"
   FROM (((("public"."parcelas" "p"
     JOIN "public"."alunos" "a" ON (("p"."aluno_id" = "a"."id")))
     JOIN "public"."planos" "pl" ON (("p"."plano_id" = "pl"."id")))
     JOIN "public"."unidades" "u" ON (("a"."unidade_id" = "u"."id")))
     LEFT JOIN "public"."tipos_pagamento" "tp" ON (("p"."tipo_pagamento_id" = "tp"."id")));


ALTER VIEW "public"."view_parcelas_completas" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."view_parcelas_atraso" AS
 SELECT "id",
    "aluno_id",
    "aluno_nome",
    "responsavel_nome",
    "telefone_responsavel",
    "email_responsavel",
    "plano_id",
    "plano_nome",
    "plano_valor",
    "tipo_pagamento_id",
    "tipo_pagamento_nome",
    "valor_original",
    "valor_desconto",
    "valor_final",
    "data_vencimento",
    "data_pagamento",
    "ano_referencia",
    "mes_referencia",
    "status",
    "observacoes",
    "comprovante_url",
    "created_at",
    "updated_at",
    "unidade_nome",
    "status_calculado",
    "dias_atraso"
   FROM "public"."view_parcelas_completas"
  WHERE ("status_calculado" = 'atrasado'::"text");


ALTER VIEW "public"."view_parcelas_atraso" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."view_recorrencias_completas" AS
 SELECT "r"."id",
    "r"."nome",
    "r"."tipo",
    "r"."percentual_desconto",
    "r"."data_inicio",
    "r"."data_fim",
    "r"."ativo",
    "r"."created_at",
    "r"."updated_at",
    COALESCE("array_agg"("u"."id" ORDER BY "u"."nome") FILTER (WHERE ("u"."id" IS NOT NULL)), '{}'::"uuid"[]) AS "unidades_ids",
    COALESCE("array_agg"("u"."nome" ORDER BY "u"."nome") FILTER (WHERE ("u"."nome" IS NOT NULL)), '{}'::character varying[]) AS "unidades_nomes"
   FROM (("public"."recorrencias" "r"
     LEFT JOIN "public"."recorrencias_unidades" "ru" ON (("r"."id" = "ru"."recorrencia_id")))
     LEFT JOIN "public"."unidades" "u" ON (("ru"."unidade_id" = "u"."id")))
  GROUP BY "r"."id", "r"."nome", "r"."tipo", "r"."percentual_desconto", "r"."data_inicio", "r"."data_fim", "r"."ativo", "r"."created_at", "r"."updated_at";


ALTER VIEW "public"."view_recorrencias_completas" OWNER TO "postgres";


COMMENT ON VIEW "public"."view_recorrencias_completas" IS 'View com recorrências e suas unidades';



CREATE OR REPLACE VIEW "public"."view_resumo_financeiro_unidade" AS
 SELECT "u"."id" AS "unidade_id",
    "u"."nome" AS "unidade_nome",
    "count"(DISTINCT "a"."id") AS "total_alunos",
    "count"(DISTINCT
        CASE
            WHEN ("a"."ativo" = true) THEN "a"."id"
            ELSE NULL::"uuid"
        END) AS "alunos_ativos",
    COALESCE("sum"(
        CASE
            WHEN ("p"."status" = 'pago'::"text") THEN "p"."valor_final"
            ELSE (0)::numeric
        END), (0)::numeric) AS "receita_paga",
    COALESCE("sum"(
        CASE
            WHEN ("p"."status" = 'pendente'::"text") THEN "p"."valor_final"
            ELSE (0)::numeric
        END), (0)::numeric) AS "receita_pendente",
    COALESCE("sum"(
        CASE
            WHEN ("p"."status" = 'vencido'::"text") THEN "p"."valor_final"
            ELSE (0)::numeric
        END), (0)::numeric) AS "receita_vencida",
    COALESCE("sum"("d"."valor"), (0)::numeric) AS "total_despesas"
   FROM ((("public"."unidades" "u"
     LEFT JOIN "public"."alunos" "a" ON (("a"."unidade_id" = "u"."id")))
     LEFT JOIN "public"."parcelas" "p" ON (("p"."aluno_id" = "a"."id")))
     LEFT JOIN "public"."despesas" "d" ON ((("d"."unidade_id" = "u"."id") AND ("d"."ativo" = true))))
  GROUP BY "u"."id", "u"."nome";


ALTER VIEW "public"."view_resumo_financeiro_unidade" OWNER TO "postgres";


ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_cpf_key" UNIQUE ("cpf");



ALTER TABLE ONLY "public"."alunos_descontos"
    ADD CONSTRAINT "alunos_descontos_aluno_id_desconto_id_key" UNIQUE ("aluno_id", "desconto_id");



ALTER TABLE ONLY "public"."alunos_descontos"
    ADD CONSTRAINT "alunos_descontos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alunos_turmas"
    ADD CONSTRAINT "alunos_turmas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comprovantes"
    ADD CONSTRAINT "comprovantes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."descontos"
    ADD CONSTRAINT "descontos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."despesas"
    ADD CONSTRAINT "despesas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."equipe_tecnica"
    ADD CONSTRAINT "equipe_tecnica_cpf_key" UNIQUE ("cpf");



ALTER TABLE ONLY "public"."equipe_tecnica"
    ADD CONSTRAINT "equipe_tecnica_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."equipe_tecnica"
    ADD CONSTRAINT "equipe_tecnica_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."equipe_unidades"
    ADD CONSTRAINT "equipe_unidades_equipe_id_unidade_id_key" UNIQUE ("equipe_id", "unidade_id");



ALTER TABLE ONLY "public"."equipe_unidades"
    ADD CONSTRAINT "equipe_unidades_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."frequencia"
    ADD CONSTRAINT "frequencia_aluno_id_turma_id_data_aula_key" UNIQUE ("aluno_id", "turma_id", "data_aula");



ALTER TABLE ONLY "public"."frequencia"
    ADD CONSTRAINT "frequencia_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."migration_log"
    ADD CONSTRAINT "migration_log_migration_name_key" UNIQUE ("migration_name");



ALTER TABLE ONLY "public"."migration_log"
    ADD CONSTRAINT "migration_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."negociacoes"
    ADD CONSTRAINT "negociacoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagamentos_descontos"
    ADD CONSTRAINT "pagamentos_descontos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagamentos"
    ADD CONSTRAINT "pagamentos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."parcelas"
    ADD CONSTRAINT "parcelas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."planos_descontos"
    ADD CONSTRAINT "planos_descontos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."planos_descontos"
    ADD CONSTRAINT "planos_descontos_plano_id_desconto_id_key" UNIQUE ("plano_id", "desconto_id");



ALTER TABLE ONLY "public"."planos"
    ADD CONSTRAINT "planos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."proporcionalidade"
    ADD CONSTRAINT "proporcionalidade_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recorrencias"
    ADD CONSTRAINT "recorrencias_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recorrencias_unidades"
    ADD CONSTRAINT "recorrencias_unidades_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recorrencias_unidades"
    ADD CONSTRAINT "recorrencias_unidades_recorrencia_id_unidade_id_key" UNIQUE ("recorrencia_id", "unidade_id");



ALTER TABLE ONLY "public"."repasses"
    ADD CONSTRAINT "repasses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."repasses"
    ADD CONSTRAINT "repasses_unidade_id_mes_ano_key" UNIQUE ("unidade_id", "mes", "ano");



ALTER TABLE ONLY "public"."tipos_pagamento"
    ADD CONSTRAINT "tipos_pagamento_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transacoes_financeiras"
    ADD CONSTRAINT "transacoes_financeiras_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."turma_horarios"
    ADD CONSTRAINT "turma_horarios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."turma_horarios"
    ADD CONSTRAINT "turma_horarios_turma_id_dia_semana_key" UNIQUE ("turma_id", "dia_semana");



ALTER TABLE ONLY "public"."turma_professores"
    ADD CONSTRAINT "turma_professores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."turma_professores"
    ADD CONSTRAINT "turma_professores_turma_id_professor_id_key" UNIQUE ("turma_id", "professor_id");



ALTER TABLE ONLY "public"."turmas"
    ADD CONSTRAINT "turmas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."turmas_professores"
    ADD CONSTRAINT "turmas_professores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."turmas_professores"
    ADD CONSTRAINT "turmas_professores_turma_id_professor_id_key" UNIQUE ("turma_id", "professor_id");



ALTER TABLE ONLY "public"."unidades"
    ADD CONSTRAINT "unidades_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_alunos_ativo" ON "public"."alunos" USING "btree" ("ativo");



CREATE INDEX "idx_alunos_categoria" ON "public"."alunos" USING "btree" ("categoria");



CREATE INDEX "idx_alunos_cpf" ON "public"."alunos" USING "btree" ("cpf");



CREATE INDEX "idx_alunos_data_saida" ON "public"."alunos" USING "btree" ("data_saida");



CREATE INDEX "idx_alunos_descontos_aluno" ON "public"."alunos_descontos" USING "btree" ("aluno_id");



CREATE INDEX "idx_alunos_descontos_ativo" ON "public"."alunos_descontos" USING "btree" ("ativo");



CREATE INDEX "idx_alunos_descontos_desconto" ON "public"."alunos_descontos" USING "btree" ("desconto_id");



CREATE INDEX "idx_alunos_descontos_expiracao" ON "public"."alunos_descontos" USING "btree" ("data_expiracao");



CREATE INDEX "idx_alunos_nome" ON "public"."alunos" USING "btree" ("nome");



CREATE INDEX "idx_alunos_plano" ON "public"."alunos" USING "btree" ("plano_id");



CREATE INDEX "idx_alunos_status" ON "public"."alunos" USING "btree" ("status") WHERE ("status" IS NOT NULL);



CREATE INDEX "idx_alunos_turma" ON "public"."alunos" USING "btree" ("turma_id");



CREATE INDEX "idx_alunos_turmas_aluno" ON "public"."alunos_turmas" USING "btree" ("aluno_id");



CREATE INDEX "idx_alunos_turmas_ativo" ON "public"."alunos_turmas" USING "btree" ("ativo");



CREATE INDEX "idx_alunos_turmas_periodo" ON "public"."alunos_turmas" USING "btree" ("data_inicio", "data_fim");



CREATE INDEX "idx_alunos_turmas_turma" ON "public"."alunos_turmas" USING "btree" ("turma_id");



CREATE INDEX "idx_alunos_unidade" ON "public"."alunos" USING "btree" ("unidade_id");



CREATE INDEX "idx_alunos_unidade_id" ON "public"."alunos" USING "btree" ("unidade_id");



CREATE INDEX "idx_descontos_ativo" ON "public"."descontos" USING "btree" ("ativo");



CREATE INDEX "idx_despesas_unidade" ON "public"."despesas" USING "btree" ("unidade_id");



CREATE INDEX "idx_despesas_unidade_id" ON "public"."despesas" USING "btree" ("unidade_id") WHERE ("unidade_id" IS NOT NULL);



CREATE INDEX "idx_equipe_tecnica_nome" ON "public"."equipe_tecnica" USING "btree" ("nome");



CREATE INDEX "idx_equipe_tecnica_status" ON "public"."equipe_tecnica" USING "btree" ("status");



CREATE INDEX "idx_equipe_tecnica_unidade" ON "public"."equipe_tecnica" USING "btree" ("unidade_id");



CREATE INDEX "idx_equipe_unidades_equipe" ON "public"."equipe_unidades" USING "btree" ("equipe_id");



CREATE INDEX "idx_frequencia_aluno" ON "public"."frequencia" USING "btree" ("aluno_id");



CREATE INDEX "idx_frequencia_data" ON "public"."frequencia" USING "btree" ("data_aula");



CREATE INDEX "idx_frequencia_turma" ON "public"."frequencia" USING "btree" ("turma_id");



CREATE INDEX "idx_migration_log_executed_at" ON "public"."migration_log" USING "btree" ("executed_at");



CREATE INDEX "idx_migration_log_name" ON "public"."migration_log" USING "btree" ("migration_name");



CREATE INDEX "idx_negociacoes_tipo" ON "public"."negociacoes" USING "btree" ("tipo");



CREATE INDEX "idx_pagamentos_aluno" ON "public"."pagamentos" USING "btree" ("aluno_id");



CREATE INDEX "idx_pagamentos_descontos_desconto" ON "public"."pagamentos_descontos" USING "btree" ("desconto_id");



CREATE INDEX "idx_pagamentos_descontos_pagamento" ON "public"."pagamentos_descontos" USING "btree" ("pagamento_id");



CREATE INDEX "idx_pagamentos_referencia" ON "public"."pagamentos" USING "btree" ("ano_referencia", "mes_referencia");



CREATE INDEX "idx_pagamentos_status" ON "public"."pagamentos" USING "btree" ("status");



CREATE INDEX "idx_pagamentos_vencimento" ON "public"."pagamentos" USING "btree" ("data_vencimento");



CREATE INDEX "idx_parcelas_aluno_id" ON "public"."parcelas" USING "btree" ("aluno_id");



CREATE INDEX "idx_parcelas_data_vencimento" ON "public"."parcelas" USING "btree" ("data_vencimento");



CREATE INDEX "idx_parcelas_status" ON "public"."parcelas" USING "btree" ("status");



CREATE INDEX "idx_planos_ativo" ON "public"."planos" USING "btree" ("ativo");



CREATE INDEX "idx_planos_descontos_ativo" ON "public"."planos_descontos" USING "btree" ("ativo");



CREATE INDEX "idx_planos_descontos_desconto" ON "public"."planos_descontos" USING "btree" ("desconto_id");



CREATE INDEX "idx_planos_descontos_plano" ON "public"."planos_descontos" USING "btree" ("plano_id");



CREATE INDEX "idx_planos_frequencia" ON "public"."planos" USING "btree" ("frequencia_treino");



CREATE INDEX "idx_planos_unidade" ON "public"."planos" USING "btree" ("unidade_id");



CREATE INDEX "idx_planos_unidade_id" ON "public"."planos" USING "btree" ("unidade_id");



CREATE INDEX "idx_profiles_ativo" ON "public"."profiles" USING "btree" ("ativo");



CREATE INDEX "idx_profiles_role" ON "public"."profiles" USING "btree" ("role");



CREATE INDEX "idx_profiles_unidade" ON "public"."profiles" USING "btree" ("unidade_id");



CREATE INDEX "idx_proporcionalidade_ativo" ON "public"."proporcionalidade" USING "btree" ("ativo");



CREATE INDEX "idx_recorrencias_ativo" ON "public"."recorrencias" USING "btree" ("ativo");



CREATE INDEX "idx_recorrencias_tipo" ON "public"."recorrencias" USING "btree" ("tipo");



CREATE INDEX "idx_recorrencias_unidades_recorrencia" ON "public"."recorrencias_unidades" USING "btree" ("recorrencia_id");



CREATE INDEX "idx_recorrencias_unidades_unidade" ON "public"."recorrencias_unidades" USING "btree" ("unidade_id");



CREATE INDEX "idx_repasses_status" ON "public"."repasses" USING "btree" ("status");



CREATE INDEX "idx_repasses_unidade_periodo" ON "public"."repasses" USING "btree" ("unidade_id", "ano", "mes");



CREATE INDEX "idx_tipos_pagamento_ativo" ON "public"."tipos_pagamento" USING "btree" ("ativo");



CREATE INDEX "idx_transacoes_data" ON "public"."transacoes_financeiras" USING "btree" ("data_transacao");



CREATE INDEX "idx_transacoes_unidade" ON "public"."transacoes_financeiras" USING "btree" ("unidade_id");



CREATE INDEX "idx_turma_horarios_turma" ON "public"."turma_horarios" USING "btree" ("turma_id");



CREATE INDEX "idx_turma_professores_turma" ON "public"."turma_professores" USING "btree" ("turma_id");



CREATE INDEX "idx_turmas_categoria" ON "public"."turmas" USING "btree" ("categoria");



CREATE INDEX "idx_turmas_professor" ON "public"."turmas" USING "btree" ("professor_id");



CREATE INDEX "idx_turmas_professores_principal" ON "public"."turmas_professores" USING "btree" ("principal");



CREATE INDEX "idx_turmas_professores_professor" ON "public"."turmas_professores" USING "btree" ("professor_id");



CREATE INDEX "idx_turmas_professores_turma" ON "public"."turmas_professores" USING "btree" ("turma_id");



CREATE INDEX "idx_turmas_status" ON "public"."turmas" USING "btree" ("status");



CREATE INDEX "idx_turmas_unidade" ON "public"."turmas" USING "btree" ("unidade_id");



CREATE INDEX "idx_turmas_unidade_id" ON "public"."turmas" USING "btree" ("unidade_id");



CREATE INDEX "idx_unidades_nome" ON "public"."unidades" USING "btree" ("nome");



CREATE OR REPLACE TRIGGER "handle_updated_at_alunos" BEFORE UPDATE ON "public"."alunos" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "handle_updated_at_descontos" BEFORE UPDATE ON "public"."descontos" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "handle_updated_at_unidades" BEFORE UPDATE ON "public"."unidades" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_equipe_tecnica" BEFORE UPDATE ON "public"."equipe_tecnica" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_alunos_categoria" BEFORE INSERT OR UPDATE OF "data_nascimento" ON "public"."alunos" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_atualizar_categoria_aluno"();



CREATE OR REPLACE TRIGGER "trigger_alunos_descontos_updated_at" BEFORE UPDATE ON "public"."alunos_descontos" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_alunos_turmas_updated_at" BEFORE UPDATE ON "public"."alunos_turmas" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_alunos_updated_at" BEFORE UPDATE ON "public"."alunos" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_atualizar_status_parcela" BEFORE INSERT OR UPDATE ON "public"."parcelas" FOR EACH ROW EXECUTE FUNCTION "public"."atualizar_status_parcela"();



CREATE OR REPLACE TRIGGER "trigger_comprovantes_updated_at" BEFORE UPDATE ON "public"."comprovantes" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_descontos_updated_at" BEFORE UPDATE ON "public"."descontos" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_despesas_updated_at" BEFORE UPDATE ON "public"."despesas" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_equipe_tecnica_updated_at" BEFORE UPDATE ON "public"."equipe_tecnica" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_frequencia_updated_at" BEFORE UPDATE ON "public"."frequencia" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_negociacoes_updated_at" BEFORE UPDATE ON "public"."negociacoes" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_pagamentos_updated_at" BEFORE UPDATE ON "public"."pagamentos" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_parcelas_updated_at" BEFORE UPDATE ON "public"."parcelas" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_planos_descontos_updated_at" BEFORE UPDATE ON "public"."planos_descontos" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_planos_updated_at" BEFORE UPDATE ON "public"."planos" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_proporcionalidade_updated_at" BEFORE UPDATE ON "public"."proporcionalidade" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_recorrencias_updated_at" BEFORE UPDATE ON "public"."recorrencias" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_repasses_updated_at" BEFORE UPDATE ON "public"."repasses" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_tipos_pagamento_updated_at" BEFORE UPDATE ON "public"."tipos_pagamento" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_transacoes_financeiras_updated_at" BEFORE UPDATE ON "public"."transacoes_financeiras" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_turma_horarios_updated_at" BEFORE UPDATE ON "public"."turma_horarios" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_turma_professores_updated_at" BEFORE UPDATE ON "public"."turma_professores" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_turmas_updated_at" BEFORE UPDATE ON "public"."turmas" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_unidades_updated_at" BEFORE UPDATE ON "public"."unidades" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "update_migration_log_updated_at" BEFORE UPDATE ON "public"."migration_log" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."alunos_descontos"
    ADD CONSTRAINT "alunos_descontos_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alunos_descontos"
    ADD CONSTRAINT "alunos_descontos_desconto_id_fkey" FOREIGN KEY ("desconto_id") REFERENCES "public"."descontos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_plano_id_fkey" FOREIGN KEY ("plano_id") REFERENCES "public"."planos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_recorrencia_id_fkey" FOREIGN KEY ("recorrencia_id") REFERENCES "public"."recorrencias"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_tipo_pagamento_id_fkey" FOREIGN KEY ("tipo_pagamento_id") REFERENCES "public"."tipos_pagamento"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_turma_id_fkey" FOREIGN KEY ("turma_id") REFERENCES "public"."turmas"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."alunos_turmas"
    ADD CONSTRAINT "alunos_turmas_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alunos_turmas"
    ADD CONSTRAINT "alunos_turmas_turma_id_fkey" FOREIGN KEY ("turma_id") REFERENCES "public"."turmas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comprovantes"
    ADD CONSTRAINT "comprovantes_parcela_id_fkey" FOREIGN KEY ("parcela_id") REFERENCES "public"."parcelas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comprovantes"
    ADD CONSTRAINT "comprovantes_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."despesas"
    ADD CONSTRAINT "despesas_equipe_id_fkey" FOREIGN KEY ("equipe_id") REFERENCES "public"."equipe_tecnica"("id");



ALTER TABLE ONLY "public"."despesas"
    ADD CONSTRAINT "despesas_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id");



ALTER TABLE ONLY "public"."equipe_tecnica"
    ADD CONSTRAINT "equipe_tecnica_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."equipe_unidades"
    ADD CONSTRAINT "equipe_unidades_equipe_id_fkey" FOREIGN KEY ("equipe_id") REFERENCES "public"."equipe_tecnica"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."equipe_unidades"
    ADD CONSTRAINT "equipe_unidades_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."frequencia"
    ADD CONSTRAINT "frequencia_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."frequencia"
    ADD CONSTRAINT "frequencia_turma_id_fkey" FOREIGN KEY ("turma_id") REFERENCES "public"."turmas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."negociacoes"
    ADD CONSTRAINT "negociacoes_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id");



ALTER TABLE ONLY "public"."negociacoes"
    ADD CONSTRAINT "negociacoes_desconto_id_fkey" FOREIGN KEY ("desconto_id") REFERENCES "public"."descontos"("id");



ALTER TABLE ONLY "public"."negociacoes"
    ADD CONSTRAINT "negociacoes_equipe_id_fkey" FOREIGN KEY ("equipe_id") REFERENCES "public"."equipe_tecnica"("id");



ALTER TABLE ONLY "public"."negociacoes"
    ADD CONSTRAINT "negociacoes_plano_id_fkey" FOREIGN KEY ("plano_id") REFERENCES "public"."planos"("id");



ALTER TABLE ONLY "public"."negociacoes"
    ADD CONSTRAINT "negociacoes_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id");



ALTER TABLE ONLY "public"."pagamentos"
    ADD CONSTRAINT "pagamentos_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pagamentos_descontos"
    ADD CONSTRAINT "pagamentos_descontos_desconto_id_fkey" FOREIGN KEY ("desconto_id") REFERENCES "public"."descontos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pagamentos_descontos"
    ADD CONSTRAINT "pagamentos_descontos_pagamento_id_fkey" FOREIGN KEY ("pagamento_id") REFERENCES "public"."pagamentos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pagamentos"
    ADD CONSTRAINT "pagamentos_plano_id_fkey" FOREIGN KEY ("plano_id") REFERENCES "public"."planos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pagamentos"
    ADD CONSTRAINT "pagamentos_tipo_pagamento_id_fkey" FOREIGN KEY ("tipo_pagamento_id") REFERENCES "public"."tipos_pagamento"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."parcelas"
    ADD CONSTRAINT "parcelas_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."parcelas"
    ADD CONSTRAINT "parcelas_plano_id_fkey" FOREIGN KEY ("plano_id") REFERENCES "public"."planos"("id");



ALTER TABLE ONLY "public"."parcelas"
    ADD CONSTRAINT "parcelas_tipo_pagamento_id_fkey" FOREIGN KEY ("tipo_pagamento_id") REFERENCES "public"."tipos_pagamento"("id");



ALTER TABLE ONLY "public"."planos_descontos"
    ADD CONSTRAINT "planos_descontos_desconto_id_fkey" FOREIGN KEY ("desconto_id") REFERENCES "public"."descontos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."planos_descontos"
    ADD CONSTRAINT "planos_descontos_plano_id_fkey" FOREIGN KEY ("plano_id") REFERENCES "public"."planos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."planos"
    ADD CONSTRAINT "planos_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."recorrencias_unidades"
    ADD CONSTRAINT "recorrencias_unidades_recorrencia_id_fkey" FOREIGN KEY ("recorrencia_id") REFERENCES "public"."recorrencias"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recorrencias_unidades"
    ADD CONSTRAINT "recorrencias_unidades_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."repasses"
    ADD CONSTRAINT "repasses_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transacoes_financeiras"
    ADD CONSTRAINT "transacoes_financeiras_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id");



ALTER TABLE ONLY "public"."transacoes_financeiras"
    ADD CONSTRAINT "transacoes_financeiras_parcela_id_fkey" FOREIGN KEY ("parcela_id") REFERENCES "public"."parcelas"("id");



ALTER TABLE ONLY "public"."transacoes_financeiras"
    ADD CONSTRAINT "transacoes_financeiras_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id");



ALTER TABLE ONLY "public"."turma_horarios"
    ADD CONSTRAINT "turma_horarios_turma_id_fkey" FOREIGN KEY ("turma_id") REFERENCES "public"."turmas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."turma_professores"
    ADD CONSTRAINT "turma_professores_professor_id_fkey" FOREIGN KEY ("professor_id") REFERENCES "public"."equipe_tecnica"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."turma_professores"
    ADD CONSTRAINT "turma_professores_turma_id_fkey" FOREIGN KEY ("turma_id") REFERENCES "public"."turmas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."turmas"
    ADD CONSTRAINT "turmas_professor_id_fkey" FOREIGN KEY ("professor_id") REFERENCES "public"."equipe_tecnica"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."turmas_professores"
    ADD CONSTRAINT "turmas_professores_professor_id_fkey" FOREIGN KEY ("professor_id") REFERENCES "public"."equipe_tecnica"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."turmas_professores"
    ADD CONSTRAINT "turmas_professores_turma_id_fkey" FOREIGN KEY ("turma_id") REFERENCES "public"."turmas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."turmas"
    ADD CONSTRAINT "turmas_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE CASCADE;



CREATE POLICY "Admins can manage all profiles" ON "public"."profiles" USING ("public"."is_admin"());



CREATE POLICY "Admins can manage all repasses" ON "public"."repasses" USING ("public"."is_admin"());



CREATE POLICY "Admins can manage proporcionalidade" ON "public"."proporcionalidade" USING ("public"."is_admin"());



CREATE POLICY "Admins can manage tipos_pagamento" ON "public"."tipos_pagamento" USING ("public"."is_admin"());



CREATE POLICY "Admins can manage unidades" ON "public"."unidades" USING ("public"."is_admin"());



CREATE POLICY "Admins can view all profiles" ON "public"."profiles" FOR SELECT USING ("public"."is_admin"());



CREATE POLICY "Authenticated users can view descontos" ON "public"."descontos" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can view proporcionalidade" ON "public"."proporcionalidade" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can view recorrencias" ON "public"."recorrencias" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can view recorrencias_unidades" ON "public"."recorrencias_unidades" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can view tipos_pagamento" ON "public"."tipos_pagamento" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can view unidades" ON "public"."unidades" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Managers can manage alunos from their unidade" ON "public"."alunos" USING (("public"."is_admin"() OR ("public"."is_manager"() AND ("unidade_id" = "public"."get_user_unidade_id"()))));



CREATE POLICY "Managers can manage alunos_descontos from their unidade" ON "public"."alunos_descontos" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "alunos_descontos"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage alunos_turmas from their unidade" ON "public"."alunos_turmas" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "alunos_turmas"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage comprovantes from their unidade" ON "public"."comprovantes" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM ("public"."parcelas" "p"
     JOIN "public"."alunos" "a" ON (("p"."aluno_id" = "a"."id")))
  WHERE (("p"."id" = "comprovantes"."parcela_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage descontos" ON "public"."descontos" USING ("public"."is_manager"());



CREATE POLICY "Managers can manage despesas from their unidade" ON "public"."despesas" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (("unidade_id" = "public"."get_user_unidade_id"()) OR ("unidade_id" IS NULL)))));



CREATE POLICY "Managers can manage equipe from their unidade" ON "public"."equipe_tecnica" USING (("public"."is_admin"() OR ("public"."is_manager"() AND ("unidade_id" = "public"."get_user_unidade_id"()))));



CREATE POLICY "Managers can manage equipe_unidades from their unidade" ON "public"."equipe_unidades" USING (("public"."is_admin"() OR ("public"."is_manager"() AND ("unidade_id" = "public"."get_user_unidade_id"()))));



CREATE POLICY "Managers can manage frequencia from their unidade" ON "public"."frequencia" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "frequencia"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage negociacoes from their unidade" ON "public"."negociacoes" USING (("public"."is_admin"() OR ("public"."is_manager"() AND ("unidade_id" = "public"."get_user_unidade_id"()))));



CREATE POLICY "Managers can manage pagamentos from their unidade" ON "public"."pagamentos" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "pagamentos"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage pagamentos_descontos from their unidade" ON "public"."pagamentos_descontos" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM ("public"."pagamentos" "pg"
     JOIN "public"."alunos" "a" ON (("pg"."aluno_id" = "a"."id")))
  WHERE (("pg"."id" = "pagamentos_descontos"."pagamento_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage parcelas from their unidade" ON "public"."parcelas" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "parcelas"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage planos from their unidade" ON "public"."planos" USING (("public"."is_admin"() OR ("public"."is_manager"() AND ("unidade_id" = "public"."get_user_unidade_id"()))));



CREATE POLICY "Managers can manage planos_descontos from their unidade" ON "public"."planos_descontos" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."planos" "p"
  WHERE (("p"."id" = "planos_descontos"."plano_id") AND ("p"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage recorrencias" ON "public"."recorrencias" USING ("public"."is_manager"());



CREATE POLICY "Managers can manage recorrencias_unidades" ON "public"."recorrencias_unidades" USING ("public"."is_manager"());



CREATE POLICY "Managers can manage transacoes from their unidade" ON "public"."transacoes_financeiras" USING (("public"."is_admin"() OR ("public"."is_manager"() AND ("unidade_id" = "public"."get_user_unidade_id"()))));



CREATE POLICY "Managers can manage turma_horarios from their unidade" ON "public"."turma_horarios" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."turmas" "t"
  WHERE (("t"."id" = "turma_horarios"."turma_id") AND ("t"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage turma_professores from their unidade" ON "public"."turma_professores" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."turmas" "t"
  WHERE (("t"."id" = "turma_professores"."turma_id") AND ("t"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can manage turmas from their unidade" ON "public"."turmas" USING (("public"."is_admin"() OR ("public"."is_manager"() AND ("unidade_id" = "public"."get_user_unidade_id"()))));



CREATE POLICY "Managers can manage turmas_professores from their unidade" ON "public"."turmas_professores" USING (("public"."is_admin"() OR ("public"."is_manager"() AND (EXISTS ( SELECT 1
   FROM "public"."turmas" "t"
  WHERE (("t"."id" = "turmas_professores"."turma_id") AND ("t"."unidade_id" = "public"."get_user_unidade_id"())))))));



CREATE POLICY "Managers can view all unidades" ON "public"."unidades" FOR SELECT USING ("public"."is_manager"());



CREATE POLICY "Users can update own profile" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view alunos from their unidade" ON "public"."alunos" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"())));



CREATE POLICY "Users can view alunos_descontos from their unidade" ON "public"."alunos_descontos" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "alunos_descontos"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view alunos_turmas from their unidade" ON "public"."alunos_turmas" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "alunos_turmas"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view comprovantes from their unidade" ON "public"."comprovantes" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM ("public"."parcelas" "p"
     JOIN "public"."alunos" "a" ON (("p"."aluno_id" = "a"."id")))
  WHERE (("p"."id" = "comprovantes"."parcela_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view despesas from their unidade" ON "public"."despesas" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"()) OR ("unidade_id" IS NULL)));



CREATE POLICY "Users can view equipe from their unidade" ON "public"."equipe_tecnica" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"()) OR ("unidade_id" IS NULL)));



CREATE POLICY "Users can view equipe_unidades from their unidade" ON "public"."equipe_unidades" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"())));



CREATE POLICY "Users can view frequencia from their unidade" ON "public"."frequencia" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "frequencia"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view negociacoes from their unidade" ON "public"."negociacoes" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"())));



CREATE POLICY "Users can view own profile" ON "public"."profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view pagamentos from their unidade" ON "public"."pagamentos" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "pagamentos"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view pagamentos_descontos from their unidade" ON "public"."pagamentos_descontos" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM ("public"."pagamentos" "pg"
     JOIN "public"."alunos" "a" ON (("pg"."aluno_id" = "a"."id")))
  WHERE (("pg"."id" = "pagamentos_descontos"."pagamento_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view parcelas from their unidade" ON "public"."parcelas" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."alunos" "a"
  WHERE (("a"."id" = "parcelas"."aluno_id") AND ("a"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view planos from their unidade" ON "public"."planos" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"())));



CREATE POLICY "Users can view planos_descontos from their unidade" ON "public"."planos_descontos" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."planos" "p"
  WHERE (("p"."id" = "planos_descontos"."plano_id") AND ("p"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view repasses from their unidade" ON "public"."repasses" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"())));



CREATE POLICY "Users can view transacoes from their unidade" ON "public"."transacoes_financeiras" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"())));



CREATE POLICY "Users can view turma_horarios from their unidade" ON "public"."turma_horarios" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."turmas" "t"
  WHERE (("t"."id" = "turma_horarios"."turma_id") AND ("t"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view turma_professores from their unidade" ON "public"."turma_professores" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."turmas" "t"
  WHERE (("t"."id" = "turma_professores"."turma_id") AND ("t"."unidade_id" = "public"."get_user_unidade_id"()))))));



CREATE POLICY "Users can view turmas from their unidade" ON "public"."turmas" FOR SELECT USING (("public"."is_admin"() OR ("unidade_id" = "public"."get_user_unidade_id"())));



CREATE POLICY "Users can view turmas_professores from their unidade" ON "public"."turmas_professores" FOR SELECT USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."turmas" "t"
  WHERE (("t"."id" = "turmas_professores"."turma_id") AND ("t"."unidade_id" = "public"."get_user_unidade_id"()))))));



ALTER TABLE "public"."alunos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."alunos_descontos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."alunos_turmas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comprovantes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."descontos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."despesas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."equipe_tecnica" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."equipe_unidades" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."frequencia" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."negociacoes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pagamentos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pagamentos_descontos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."parcelas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."planos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."planos_descontos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."proporcionalidade" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recorrencias" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recorrencias_unidades" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."repasses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tipos_pagamento" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transacoes_financeiras" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."turma_horarios" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."turma_professores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."turmas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."turmas_professores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."unidades" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."atualizar_status_parcela"() TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_status_parcela"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_status_parcela"() TO "service_role";



GRANT ALL ON FUNCTION "public"."calcular_desconto_proporcional"("data_inicio" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."calcular_desconto_proporcional"("data_inicio" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_desconto_proporcional"("data_inicio" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."calcular_idade"("data_nascimento" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."calcular_idade"("data_nascimento" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_idade"("data_nascimento" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."calcular_valor_com_desconto"("valor_original" numeric, "percentual_desconto" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."calcular_valor_com_desconto"("valor_original" numeric, "percentual_desconto" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_valor_com_desconto"("valor_original" numeric, "percentual_desconto" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."calcular_valor_transferencia"("p_valor_base" numeric, "p_tipo_repasse" "text", "p_valor_repasse" numeric, "p_percentual_repasse" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."calcular_valor_transferencia"("p_valor_base" numeric, "p_tipo_repasse" "text", "p_valor_repasse" numeric, "p_percentual_repasse" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_valor_transferencia"("p_valor_base" numeric, "p_tipo_repasse" "text", "p_valor_repasse" numeric, "p_percentual_repasse" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."determinar_categoria"("data_nascimento" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."determinar_categoria"("data_nascimento" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."determinar_categoria"("data_nascimento" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."gerar_parcelas_aluno"("p_aluno_id" "uuid", "p_plano_id" "uuid", "p_data_inicio" "date", "p_numero_parcelas" integer, "p_aplicar_proporcionalidade" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."gerar_parcelas_aluno"("p_aluno_id" "uuid", "p_plano_id" "uuid", "p_data_inicio" "date", "p_numero_parcelas" integer, "p_aplicar_proporcionalidade" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."gerar_parcelas_aluno"("p_aluno_id" "uuid", "p_plano_id" "uuid", "p_data_inicio" "date", "p_numero_parcelas" integer, "p_aplicar_proporcionalidade" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."gerar_proximo_vencimento"("data_base" "date", "tipo_recorrencia" "public"."recorrencia_tipo") TO "anon";
GRANT ALL ON FUNCTION "public"."gerar_proximo_vencimento"("data_base" "date", "tipo_recorrencia" "public"."recorrencia_tipo") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gerar_proximo_vencimento"("data_base" "date", "tipo_recorrencia" "public"."recorrencia_tipo") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_unidade_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_unidade_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_unidade_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_manager"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_manager"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_manager"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_atualizar_categoria_aluno"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_atualizar_categoria_aluno"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_atualizar_categoria_aluno"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON TABLE "public"."alunos" TO "anon";
GRANT ALL ON TABLE "public"."alunos" TO "authenticated";
GRANT ALL ON TABLE "public"."alunos" TO "service_role";



GRANT ALL ON TABLE "public"."planos" TO "anon";
GRANT ALL ON TABLE "public"."planos" TO "authenticated";
GRANT ALL ON TABLE "public"."planos" TO "service_role";



GRANT ALL ON TABLE "public"."recorrencias" TO "anon";
GRANT ALL ON TABLE "public"."recorrencias" TO "authenticated";
GRANT ALL ON TABLE "public"."recorrencias" TO "service_role";



GRANT ALL ON TABLE "public"."tipos_pagamento" TO "anon";
GRANT ALL ON TABLE "public"."tipos_pagamento" TO "authenticated";
GRANT ALL ON TABLE "public"."tipos_pagamento" TO "service_role";



GRANT ALL ON TABLE "public"."turmas" TO "anon";
GRANT ALL ON TABLE "public"."turmas" TO "authenticated";
GRANT ALL ON TABLE "public"."turmas" TO "service_role";



GRANT ALL ON TABLE "public"."unidades" TO "anon";
GRANT ALL ON TABLE "public"."unidades" TO "authenticated";
GRANT ALL ON TABLE "public"."unidades" TO "service_role";



GRANT ALL ON TABLE "public"."alunos_completos" TO "anon";
GRANT ALL ON TABLE "public"."alunos_completos" TO "authenticated";
GRANT ALL ON TABLE "public"."alunos_completos" TO "service_role";



GRANT ALL ON TABLE "public"."alunos_descontos" TO "anon";
GRANT ALL ON TABLE "public"."alunos_descontos" TO "authenticated";
GRANT ALL ON TABLE "public"."alunos_descontos" TO "service_role";



GRANT ALL ON TABLE "public"."alunos_turmas" TO "anon";
GRANT ALL ON TABLE "public"."alunos_turmas" TO "authenticated";
GRANT ALL ON TABLE "public"."alunos_turmas" TO "service_role";



GRANT ALL ON TABLE "public"."comprovantes" TO "anon";
GRANT ALL ON TABLE "public"."comprovantes" TO "authenticated";
GRANT ALL ON TABLE "public"."comprovantes" TO "service_role";



GRANT ALL ON TABLE "public"."descontos" TO "anon";
GRANT ALL ON TABLE "public"."descontos" TO "authenticated";
GRANT ALL ON TABLE "public"."descontos" TO "service_role";



GRANT ALL ON TABLE "public"."despesas" TO "anon";
GRANT ALL ON TABLE "public"."despesas" TO "authenticated";
GRANT ALL ON TABLE "public"."despesas" TO "service_role";



GRANT ALL ON TABLE "public"."equipe_tecnica" TO "anon";
GRANT ALL ON TABLE "public"."equipe_tecnica" TO "authenticated";
GRANT ALL ON TABLE "public"."equipe_tecnica" TO "service_role";



GRANT ALL ON TABLE "public"."equipe_unidades" TO "anon";
GRANT ALL ON TABLE "public"."equipe_unidades" TO "authenticated";
GRANT ALL ON TABLE "public"."equipe_unidades" TO "service_role";



GRANT ALL ON TABLE "public"."frequencia" TO "anon";
GRANT ALL ON TABLE "public"."frequencia" TO "authenticated";
GRANT ALL ON TABLE "public"."frequencia" TO "service_role";



GRANT ALL ON TABLE "public"."migration_log" TO "anon";
GRANT ALL ON TABLE "public"."migration_log" TO "authenticated";
GRANT ALL ON TABLE "public"."migration_log" TO "service_role";



GRANT ALL ON TABLE "public"."negociacoes" TO "anon";
GRANT ALL ON TABLE "public"."negociacoes" TO "authenticated";
GRANT ALL ON TABLE "public"."negociacoes" TO "service_role";



GRANT ALL ON TABLE "public"."pagamentos" TO "anon";
GRANT ALL ON TABLE "public"."pagamentos" TO "authenticated";
GRANT ALL ON TABLE "public"."pagamentos" TO "service_role";



GRANT ALL ON TABLE "public"."pagamentos_completos" TO "anon";
GRANT ALL ON TABLE "public"."pagamentos_completos" TO "authenticated";
GRANT ALL ON TABLE "public"."pagamentos_completos" TO "service_role";



GRANT ALL ON TABLE "public"."pagamentos_descontos" TO "anon";
GRANT ALL ON TABLE "public"."pagamentos_descontos" TO "authenticated";
GRANT ALL ON TABLE "public"."pagamentos_descontos" TO "service_role";



GRANT ALL ON TABLE "public"."parcelas" TO "anon";
GRANT ALL ON TABLE "public"."parcelas" TO "authenticated";
GRANT ALL ON TABLE "public"."parcelas" TO "service_role";



GRANT ALL ON TABLE "public"."planos_descontos" TO "anon";
GRANT ALL ON TABLE "public"."planos_descontos" TO "authenticated";
GRANT ALL ON TABLE "public"."planos_descontos" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."proporcionalidade" TO "anon";
GRANT ALL ON TABLE "public"."proporcionalidade" TO "authenticated";
GRANT ALL ON TABLE "public"."proporcionalidade" TO "service_role";



GRANT ALL ON TABLE "public"."recorrencias_unidades" TO "anon";
GRANT ALL ON TABLE "public"."recorrencias_unidades" TO "authenticated";
GRANT ALL ON TABLE "public"."recorrencias_unidades" TO "service_role";



GRANT ALL ON TABLE "public"."repasses" TO "anon";
GRANT ALL ON TABLE "public"."repasses" TO "authenticated";
GRANT ALL ON TABLE "public"."repasses" TO "service_role";



GRANT ALL ON TABLE "public"."transacoes_financeiras" TO "anon";
GRANT ALL ON TABLE "public"."transacoes_financeiras" TO "authenticated";
GRANT ALL ON TABLE "public"."transacoes_financeiras" TO "service_role";



GRANT ALL ON TABLE "public"."turma_horarios" TO "anon";
GRANT ALL ON TABLE "public"."turma_horarios" TO "authenticated";
GRANT ALL ON TABLE "public"."turma_horarios" TO "service_role";



GRANT ALL ON TABLE "public"."turma_professores" TO "anon";
GRANT ALL ON TABLE "public"."turma_professores" TO "authenticated";
GRANT ALL ON TABLE "public"."turma_professores" TO "service_role";



GRANT ALL ON TABLE "public"."turmas_completas" TO "anon";
GRANT ALL ON TABLE "public"."turmas_completas" TO "authenticated";
GRANT ALL ON TABLE "public"."turmas_completas" TO "service_role";



GRANT ALL ON TABLE "public"."turmas_professores" TO "anon";
GRANT ALL ON TABLE "public"."turmas_professores" TO "authenticated";
GRANT ALL ON TABLE "public"."turmas_professores" TO "service_role";



GRANT ALL ON TABLE "public"."view_parcelas_completas" TO "anon";
GRANT ALL ON TABLE "public"."view_parcelas_completas" TO "authenticated";
GRANT ALL ON TABLE "public"."view_parcelas_completas" TO "service_role";



GRANT ALL ON TABLE "public"."view_parcelas_atraso" TO "anon";
GRANT ALL ON TABLE "public"."view_parcelas_atraso" TO "authenticated";
GRANT ALL ON TABLE "public"."view_parcelas_atraso" TO "service_role";



GRANT ALL ON TABLE "public"."view_recorrencias_completas" TO "anon";
GRANT ALL ON TABLE "public"."view_recorrencias_completas" TO "authenticated";
GRANT ALL ON TABLE "public"."view_recorrencias_completas" TO "service_role";



GRANT ALL ON TABLE "public"."view_resumo_financeiro_unidade" TO "anon";
GRANT ALL ON TABLE "public"."view_resumo_financeiro_unidade" TO "authenticated";
GRANT ALL ON TABLE "public"."view_resumo_financeiro_unidade" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






