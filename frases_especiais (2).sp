/**
 * frases_especiais.sp
 * Exibe frases no chat baseadas em ações do jogador.
 *
 * Tipos de frase:
 *   cura          - se curar (medkit/pills/adrenalina)
 *   cura_outros   - curar outra pessoa
 *   tank          - matar Tank (último hit)
 *   levantar      - levantar alguém do chão
 *   defib         - ressuscitar com desfibrilador
 *   respawn       - abrir porta de respawn
 *   parapeito     - puxar alguém do parapeito
 *   agradece_cura      - alguém te curou
 *   agradece_levantar  - alguém te levantou
 *   agradece_defib     - alguém te ressuscitou com defib
 *   agradece_respawn   - alguém te resgatou do respawn
 *   agradece_parapeito - alguém te puxou do parapeito
 *
 * Comandos (apenas admins):
 *   sm_frase_add <#userid|nome> <tipo|tudo>       - autoriza jogador
 *   sm_frase_remove <#userid|nome> <tipo|tudo>    - remove autorização
 *   sm_frase_set <tipo> <frase>                   - customiza frase global
 *   sm_frase_lista                                - lista autorizados
 *
 * Banco: SQLite (addons/sourcemod/data/frases_especiais.sq3)
 *
 * Compilar:  spcomp frases_especiais.sp
 * Instalar:  addons/sourcemod/plugins/frases_especiais.smx
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "2.0"

// --- Índices dos tipos de frase ---
#define FRASE_CURA               0
#define FRASE_CURA_OUTROS        1
#define FRASE_TANK               2
#define FRASE_LEVANTAR           3
#define FRASE_DEFIB              4
#define FRASE_RESPAWN            5
#define FRASE_PARAPEITO          6
#define FRASE_AGRADECE_CURA      7
#define FRASE_AGRADECE_LEVANTAR  8
#define FRASE_AGRADECE_DEFIB     9
#define FRASE_AGRADECE_RESPAWN   10
#define FRASE_AGRADECE_PARAPEITO 11
#define FRASE_MAX                12

// Bitmasks
#define BIT(%1) (1 << %1)
#define FRASE_TUDO ((1 << FRASE_MAX) - 1)

public Plugin myinfo =
{
    name        = "Frases Especiais",
    author      = "Mika e PV",
    description = "Frases no chat baseadas em ações do jogador",
    version     = PLUGIN_VERSION,
    url         = ""
};

// --- Frases padrão ---
char g_sDefaultFrases[FRASE_MAX][] = {
    "I'M NOT READY TO DIE!",                    // cura
    "YOU WON'T DIE ON MY WATCH!",               // cura_outros
    "I KILLED A TANK! I'M UNSTOPPABLE!",        // tank
    "Get up, we're not done yet!",              // levantar
    "Death is not an option!",                  // defib
    "Nobody gets left behind!",                 // respawn
    "I got you, hang on!",                      // parapeito
    "Thanks for healing me!",                   // agradece_cura
    "Thanks for picking me up!",                // agradece_levantar
    "I was gone... Thanks for bringing me back!", // agradece_defib
    "Thanks for rescuing me!",                  // agradece_respawn
    "Thanks for pulling me up!"                 // agradece_parapeito
};

char g_sFraseNomes[FRASE_MAX][] = {
    "cura", "cura_outros", "tank", "levantar", "defib", "respawn", "parapeito",
    "agradece_cura", "agradece_levantar", "agradece_defib", "agradece_respawn", "agradece_parapeito"
};

// --- Frases customizadas (carregadas do banco) ---
char g_sFrases[FRASE_MAX][256];

// --- Banco e cache ---
Database  g_hDB    = null;
StringMap g_hCache = null;  // steamid -> bitmask de frases autorizadas

// --- Rastreamento do último hit no Tank ---
int g_iLastHitTank[MAXPLAYERS + 1];  // client -> ref do tank que atacou por último
int g_iTankLastAttacker[MAXPLAYERS + 1]; // slot tank -> último atacante (por ref do tank)

// -------------------------------------------------------------------------
public void OnPluginStart()
{
    CreateConVar("sm_frases_version", PLUGIN_VERSION, "Frases Especiais version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    RegAdminCmd("sm_frase_add",    Cmd_Add,    ADMFLAG_GENERIC, "sm_frase_add <#userid|nome> <tipo|tudo>");
    RegAdminCmd("sm_frase_remove", Cmd_Remove, ADMFLAG_GENERIC, "sm_frase_remove <#userid|nome> <tipo|tudo>");
    RegAdminCmd("sm_frase_set",    Cmd_Set,    ADMFLAG_GENERIC, "sm_frase_set <tipo> <frase>");
    RegAdminCmd("sm_frase_lista",  Cmd_Lista,  ADMFLAG_GENERIC, "Lista jogadores autorizados");

    // Cura
    HookEvent("heal_success",    Event_HealSuccess,  EventHookMode_Post);
    HookEvent("pills_used",      Event_PillsAdren,   EventHookMode_Post);
    HookEvent("adrenaline_used", Event_PillsAdren,   EventHookMode_Post);

    // Tank
    HookEvent("player_hurt",     Event_PlayerHurt,   EventHookMode_Post);
    HookEvent("tank_killed",     Event_TankKilled,   EventHookMode_Post);

    // Levantar / defib / respawn / parapeito
    HookEvent("revive_success",  Event_ReviveSuccess, EventHookMode_Post);
    HookEvent("defibrillator_used", Event_Defib,     EventHookMode_Post);
    HookEvent("survival_round_start", Event_Respawn, EventHookMode_Post); // fallback
    HookEvent("player_ledge_grab", Event_Parapeito,  EventHookMode_Post);

    g_hCache = new StringMap();

    // Copia frases padrão para frases ativas
    for (int i = 0; i < FRASE_MAX; i++)
        strcopy(g_sFrases[i], sizeof(g_sFrases[]), g_sDefaultFrases[i]);

    ConnectDB();
}

// --- Banco ---
void ConnectDB()
{
    char error[256];
    g_hDB = SQLite_UseDatabase("frases_especiais", error, sizeof(error));
    if (g_hDB == null) { LogError("[Frases] Erro ao conectar: %s", error); return; }

    g_hDB.Query(DB_CreateTables,
        "CREATE TABLE IF NOT EXISTS autorizados (\
            steamid TEXT PRIMARY KEY, \
            nome    TEXT, \
            flags   INTEGER NOT NULL DEFAULT 0\
        );\
        CREATE TABLE IF NOT EXISTS frases_custom (\
            tipo  TEXT PRIMARY KEY, \
            frase TEXT NOT NULL\
        );");
}

public void DB_CreateTables(Database db, DBResultSet res, const char[] err, any data)
{
    if (res == null) { LogError("[Frases] Erro ao criar tabelas: %s", err); return; }
    db.Query(DB_LoadAutorizados, "SELECT steamid, flags FROM autorizados");
    db.Query(DB_LoadFrases,      "SELECT tipo, frase FROM frases_custom");
}

public void DB_LoadAutorizados(Database db, DBResultSet res, const char[] err, any data)
{
    if (res == null) { LogError("[Frases] Erro ao carregar autorizados: %s", err); return; }
    g_hCache.Clear();
    while (res.FetchRow())
    {
        char steamid[64];
        res.FetchString(0, steamid, sizeof(steamid));
        int flags = res.FetchInt(1);
        g_hCache.SetValue(steamid, flags);
    }
}

public void DB_LoadFrases(Database db, DBResultSet res, const char[] err, any data)
{
    if (res == null) { LogError("[Frases] Erro ao carregar frases: %s", err); return; }
    while (res.FetchRow())
    {
        char tipo[64], frase[256];
        res.FetchString(0, tipo, sizeof(tipo));
        res.FetchString(1, frase, sizeof(frase));
        int idx = FindFraseIdx(tipo);
        if (idx != -1)
            strcopy(g_sFrases[idx], sizeof(g_sFrases[]), frase);
    }
}

void DB_UpsertAutorizado(const char[] steamid, const char[] nome, int flags)
{
    char query[512], safenome[128];
    g_hDB.Escape(nome, safenome, sizeof(safenome));
    Format(query, sizeof(query),
        "INSERT INTO autorizados (steamid,nome,flags) VALUES('%s','%s',%d) \
         ON CONFLICT(steamid) DO UPDATE SET nome='%s',flags=%d",
        steamid, safenome, flags, safenome, flags);
    g_hDB.Query(DB_Generic, query);
}

void DB_DeleteAutorizado(const char[] steamid)
{
    char query[256];
    Format(query, sizeof(query), "DELETE FROM autorizados WHERE steamid='%s'", steamid);
    g_hDB.Query(DB_Generic, query);
}

void DB_UpsertFrase(const char[] tipo, const char[] frase)
{
    char query[512], safefrase[512];
    g_hDB.Escape(frase, safefrase, sizeof(safefrase));
    Format(query, sizeof(query),
        "INSERT INTO frases_custom (tipo,frase) VALUES('%s','%s') \
         ON CONFLICT(tipo) DO UPDATE SET frase='%s'",
        tipo, safefrase, safefrase);
    g_hDB.Query(DB_Generic, query);
}

public void DB_Generic(Database db, DBResultSet res, const char[] err, any data)
{
    if (res == null) LogError("[Frases] Erro de query: %s", err);
}

// --- Comandos ---
public Action Cmd_Add(int client, int args)
{
    if (args < 2) { ReplyToCommand(client, "[Frases] Uso: sm_frase_add <#userid|nome> <tipo|tudo>"); return Plugin_Handled; }

    char arg1[64], arg2[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    GetCmdArg(2, arg2, sizeof(arg2));

    int target = FindTarget(client, arg1, false, false);
    if (target == -1) return Plugin_Handled;

    int flag = ParseTipo(arg2);
    if (flag == -1) { ReplyToCommand(client, "[Frases] Tipo invalido. Use um tipo valido ou 'tudo'"); return Plugin_Handled; }

    char steamid[64], nome[MAX_NAME_LENGTH];
    GetClientAuthId(target, AuthId_Steam2, steamid, sizeof(steamid));
    GetClientName(target, nome, sizeof(nome));

    int current = 0;
    g_hCache.GetValue(steamid, current);
    int newflags = current | flag;

    g_hCache.SetValue(steamid, newflags);
    DB_UpsertAutorizado(steamid, nome, newflags);
    ReplyToCommand(client, "[Frases] %s autorizado(a): %s", nome, arg2);
    return Plugin_Handled;
}

public Action Cmd_Remove(int client, int args)
{
    if (args < 2) { ReplyToCommand(client, "[Frases] Uso: sm_frase_remove <#userid|nome> <tipo|tudo>"); return Plugin_Handled; }

    char arg1[64], arg2[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    GetCmdArg(2, arg2, sizeof(arg2));

    int target = FindTarget(client, arg1, false, false);
    if (target == -1) return Plugin_Handled;

    int flag = ParseTipo(arg2);
    if (flag == -1) { ReplyToCommand(client, "[Frases] Tipo invalido."); return Plugin_Handled; }

    char steamid[64], nome[MAX_NAME_LENGTH];
    GetClientAuthId(target, AuthId_Steam2, steamid, sizeof(steamid));
    GetClientName(target, nome, sizeof(nome));

    int current = 0;
    g_hCache.GetValue(steamid, current);
    int newflags = current & ~flag;

    if (newflags == 0)
    {
        g_hCache.Remove(steamid);
        DB_DeleteAutorizado(steamid);
        ReplyToCommand(client, "[Frases] %s removido(a) completamente.", nome);
    }
    else
    {
        g_hCache.SetValue(steamid, newflags);
        DB_UpsertAutorizado(steamid, nome, newflags);
        ReplyToCommand(client, "[Frases] Tipo '%s' removido de %s.", arg2, nome);
    }
    return Plugin_Handled;
}

public Action Cmd_Set(int client, int args)
{
    if (args < 2) { ReplyToCommand(client, "[Frases] Uso: sm_frase_set <tipo> <frase>"); return Plugin_Handled; }

    char tipo[64];
    GetCmdArg(1, tipo, sizeof(tipo));

    int idx = FindFraseIdx(tipo);
    if (idx == -1) { ReplyToCommand(client, "[Frases] Tipo invalido."); return Plugin_Handled; }

    char frase[256];
    GetCmdArgString(frase, sizeof(frase));
    // Remove o primeiro argumento (tipo) da string
    int pos = 0;
    while (frase[pos] != ' ' && frase[pos] != '\0') pos++;
    while (frase[pos] == ' ') pos++;

    strcopy(g_sFrases[idx], sizeof(g_sFrases[]), frase[pos]);
    DB_UpsertFrase(tipo, frase[pos]);
    ReplyToCommand(client, "[Frases] Frase '%s' atualizada: %s", tipo, frase[pos]);
    return Plugin_Handled;
}

public Action Cmd_Lista(int client, int args)
{
    if (g_hDB == null) { ReplyToCommand(client, "[Frases] Banco indisponivel."); return Plugin_Handled; }
    g_hDB.Query(DB_Lista, "SELECT nome, steamid, flags FROM autorizados ORDER BY nome", GetClientUserId(client));
    return Plugin_Handled;
}

public void DB_Lista(Database db, DBResultSet res, const char[] err, any data)
{
    int client = GetClientOfUserId(view_as<int>(data));
    if (res == null || !IsValidClient(client)) return;
    if (!res.RowCount) { ReplyToCommand(client, "[Frases] Nenhum autorizado."); return; }

    ReplyToCommand(client, "[Frases] === Autorizados ===");
    while (res.FetchRow())
    {
        char nome[MAX_NAME_LENGTH], steamid[64];
        res.FetchString(0, nome, sizeof(nome));
        res.FetchString(1, steamid, sizeof(steamid));
        int flags = res.FetchInt(2);
        ReplyToCommand(client, "  %s (%s) flags=%d", nome, steamid, flags);
    }
}

// --- Eventos ---

// Medkit — verifica se curou a si mesmo ou outro
public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int healer  = GetClientOfUserId(event.GetInt("userid"));
    int subject = GetClientOfUserId(event.GetInt("subject"));

    if (healer == subject)
        TriggerFrase(healer, BIT(FRASE_CURA));
    else
    {
        TriggerFrase(healer,  BIT(FRASE_CURA_OUTROS));
        TriggerFrase(subject, BIT(FRASE_AGRADECE_CURA));
    }
}

// Pills / adrenalina — sempre em si mesmo
public void Event_PillsAdren(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    TriggerFrase(client, BIT(FRASE_CURA));
}

// Rastreia último atacante do Tank
public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsValidClient(victim) || !IsValidClient(attacker)) return;
    if (GetClientTeam(victim) != 3) return;
    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != 8) return; // só Tank

    g_iTankLastAttacker[victim] = attacker;
}

// Tank morreu — quem deu o último hit leva o crédito
public void Event_TankKilled(Event event, const char[] name, bool dontBroadcast)
{
    int tank = GetClientOfUserId(event.GetInt("userid"));

    int killer = 0;
    if (IsValidClient(tank))
        killer = g_iTankLastAttacker[tank];

    if (killer == 0)
        killer = GetClientOfUserId(event.GetInt("attacker"));

    if (IsValidClient(killer))
        TriggerFrase(killer, BIT(FRASE_TANK));

    // Limpa rastreamento
    if (IsValidClient(tank))
        g_iTankLastAttacker[tank] = 0;
}

// Levantar do chão / parapeito
public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int helper  = GetClientOfUserId(event.GetInt("userid"));
    int subject = GetClientOfUserId(event.GetInt("subject"));
    bool ledge  = view_as<bool>(event.GetBool("ledge_hang"));

    if (ledge)
    {
        TriggerFrase(helper,  BIT(FRASE_PARAPEITO));
        TriggerFrase(subject, BIT(FRASE_AGRADECE_PARAPEITO));
    }
    else
    {
        TriggerFrase(helper,  BIT(FRASE_LEVANTAR));
        TriggerFrase(subject, BIT(FRASE_AGRADECE_LEVANTAR));
    }
}

// Desfibrilador
public void Event_Defib(Event event, const char[] name, bool dontBroadcast)
{
    int helper  = GetClientOfUserId(event.GetInt("userid"));
    int subject = GetClientOfUserId(event.GetInt("subject"));

    TriggerFrase(helper,  BIT(FRASE_DEFIB));
    TriggerFrase(subject, BIT(FRASE_AGRADECE_DEFIB));
}

// Porta de respawn
public void Event_Respawn(Event event, const char[] name, bool dontBroadcast)
{
    // Evento genérico — tenta pegar quem abriu a porta
    int helper = GetClientOfUserId(event.GetInt("userid"));
    TriggerFrase(helper, BIT(FRASE_RESPAWN));
}

// --- Core ---
void TriggerFrase(int client, int flag)
{
    if (!IsValidClient(client) || IsFakeClient(client)) return;

    char steamid[64];
    GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

    int flags = 0;
    if (!g_hCache.GetValue(steamid, flags)) return;
    if (!(flags & flag)) return;

    // Encontra o índice da frase
    int idx = -1;
    for (int i = 0; i < FRASE_MAX; i++)
    {
        if (flag == BIT(i)) { idx = i; break; }
    }
    if (idx == -1) return;

    char nome[MAX_NAME_LENGTH];
    GetClientName(client, nome, sizeof(nome));

    PrintToChatAll("\x03%s\x01 : \x04%s", nome, g_sFrases[idx]);
}

// --- Helpers ---
int ParseTipo(const char[] arg)
{
    if (StrEqual(arg, "tudo", false)) return FRASE_TUDO;
    int idx = FindFraseIdx(arg);
    if (idx == -1) return -1;
    return BIT(idx);
}

int FindFraseIdx(const char[] tipo)
{
    for (int i = 0; i < FRASE_MAX; i++)
        if (StrEqual(tipo, g_sFraseNomes[i], false)) return i;
    return -1;
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}
