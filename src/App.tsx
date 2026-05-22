import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Copy,
  Dice5,
  DoorOpen,
  Loader2,
  LogIn,
  Play,
  Plus,
  RefreshCw,
  Swords,
} from 'lucide-react';
import { isSupabaseConfigured, supabase } from './lib/supabase';
import {
  BidOption,
  GameState,
  RpcSessionPayload,
  Session,
  clearSession,
  describeBid,
  generateBidOptions,
  loadSession,
  outcomeLabel,
  saveSession,
} from './lib/game';

type PendingAction = 'create' | 'join' | 'start' | 'bid' | 'challenge' | 'refresh' | null;

function App() {
  const [session, setSession] = useState<Session | null>(() => loadSession());
  const [state, setState] = useState<GameState | null>(null);
  const [playerName, setPlayerName] = useState('');
  const [joinCode, setJoinCode] = useState('');
  const [selectedRank, setSelectedRank] = useState<number | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingAction>(null);
  const [error, setError] = useState<string | null>(null);

  const totalDice = useMemo(
    () =>
      state?.players
        .filter((player) => !player.is_eliminated)
        .reduce((sum, player) => sum + player.dice_count, 0) ?? 0,
    [state?.players],
  );

  const bidOptions = useMemo(() => {
    const currentRank = state?.round?.current_bid?.rank ?? 0;
    return generateBidOptions(totalDice, currentRank);
  }, [state?.round?.current_bid?.rank, totalDice]);

  const selectedBid = bidOptions.find((option) => option.rank === selectedRank) ?? bidOptions[0];
  const me = state?.me ?? null;
  const currentBid = state?.round?.current_bid ?? null;
  const currentTurnPlayer = state?.players.find(
    (player) => player.id === state.game.current_turn_player_id,
  );
  const declarer = currentBid
    ? state?.players.find((player) => player.id === currentBid.player_id)
    : null;
  const winner = state?.players.find((player) => player.id === state.game.winner_player_id);
  const canStart =
    state?.game.status === 'waiting' &&
    me?.is_host &&
    state.players.filter((player) => !player.is_eliminated).length >= 2;
  const canBid =
    state?.game.status === 'playing' &&
    me &&
    !me.is_eliminated &&
    state.game.current_turn_player_id === me.id &&
    bidOptions.length > 0;
  const canChallenge =
    state?.game.status === 'playing' &&
    me &&
    !me.is_eliminated &&
    currentBid &&
    currentBid.player_id !== me.id;

  const refreshState = useCallback(
    async (action: PendingAction = 'refresh') => {
      if (!session || !supabase) {
        return;
      }

      setPendingAction(action);
      const { data, error: rpcError } = await supabase.rpc('app_state', {
        p_game_id: session.gameId,
        p_player_id: session.playerId,
        p_player_token: session.playerToken,
      });

      if (rpcError) {
        setError(rpcError.message);
      } else {
        setState(data as GameState);
        setError(null);
      }

      setPendingAction(null);
    },
    [session],
  );

  useEffect(() => {
    if (!session) {
      setState(null);
      return;
    }

    void refreshState('refresh');
    const interval = window.setInterval(() => {
      void refreshState(null);
    }, 1800);

    return () => window.clearInterval(interval);
  }, [refreshState, session]);

  useEffect(() => {
    if (bidOptions.length > 0 && !bidOptions.some((option) => option.rank === selectedRank)) {
      setSelectedRank(bidOptions[0].rank);
    }
  }, [bidOptions, selectedRank]);

  async function createGame() {
    if (!supabase || !playerName.trim()) {
      return;
    }

    setPendingAction('create');
    const { data, error: rpcError } = await supabase.rpc('create_game', {
      p_player_name: playerName.trim(),
    });

    handleSessionRpc(data as RpcSessionPayload | null, rpcError?.message ?? null);
    setPendingAction(null);
  }

  async function joinGame() {
    if (!supabase || !playerName.trim() || !joinCode.trim()) {
      return;
    }

    setPendingAction('join');
    const { data, error: rpcError } = await supabase.rpc('join_game', {
      p_code: joinCode.trim().toUpperCase(),
      p_player_name: playerName.trim(),
    });

    handleSessionRpc(data as RpcSessionPayload | null, rpcError?.message ?? null);
    setPendingAction(null);
  }

  function handleSessionRpc(payload: RpcSessionPayload | null, rpcError: string | null) {
    if (rpcError || !payload) {
      setError(rpcError ?? '요청에 실패했습니다.');
      return;
    }

    const nextSession = {
      gameId: payload.game_id,
      code: payload.code,
      playerId: payload.player_id,
      playerToken: payload.player_token,
    };
    saveSession(nextSession);
    setSession(nextSession);
    setError(null);
  }

  async function startGame() {
    if (!supabase || !session || !canStart) {
      return;
    }

    setPendingAction('start');
    const { data, error: rpcError } = await supabase.rpc('start_game', {
      p_game_id: session.gameId,
      p_player_id: session.playerId,
      p_player_token: session.playerToken,
    });
    handleStateRpc(data as GameState | null, rpcError?.message ?? null);
    setPendingAction(null);
  }

  async function placeBid() {
    if (!supabase || !session || !canBid || !selectedBid) {
      return;
    }

    setPendingAction('bid');
    const { data, error: rpcError } = await supabase.rpc('place_bid', {
      p_game_id: session.gameId,
      p_player_id: session.playerId,
      p_player_token: session.playerToken,
      p_quantity: selectedBid.quantity,
      p_face: selectedBid.face,
      p_is_special_six: selectedBid.isSpecialSix,
    });
    handleStateRpc(data as GameState | null, rpcError?.message ?? null);
    setPendingAction(null);
  }

  async function challengeBid() {
    if (!supabase || !session || !canChallenge) {
      return;
    }

    setPendingAction('challenge');
    const { data, error: rpcError } = await supabase.rpc('challenge_bid', {
      p_game_id: session.gameId,
      p_player_id: session.playerId,
      p_player_token: session.playerToken,
    });
    handleStateRpc(data as GameState | null, rpcError?.message ?? null);
    setPendingAction(null);
  }

  function handleStateRpc(payload: GameState | null, rpcError: string | null) {
    if (rpcError || !payload) {
      setError(rpcError ?? '요청에 실패했습니다.');
      return;
    }

    setState(payload);
    setError(null);
  }

  function leaveLocalSession() {
    clearSession();
    setSession(null);
    setState(null);
    setError(null);
  }

  async function copyCode() {
    if (!session?.code) {
      return;
    }
    await navigator.clipboard.writeText(session.code);
  }

  if (!isSupabaseConfigured) {
    return <SetupScreen />;
  }

  if (!session) {
    return (
      <main className="shell auth-shell">
        <section className="brand-panel">
          <div className="brand-mark">
            <Dice5 size={34} />
          </div>
          <h1>Bluff</h1>
          <p>누구도 괜찮지 않은 밤 멤버들이 모여 가볍게 할 수 있는 블러프 주사위 게임입니다.</p>
          <img
            className="meeting-cover"
            src="/meeting-cover.svg"
            alt="누구도 괜찮지 않은 밤 대표 이미지"
          />
        </section>

        <section className="auth-panel">
          <label>
            닉네임
            <input
              value={playerName}
              maxLength={18}
              placeholder="예: minsu"
              onChange={(event) => setPlayerName(event.target.value)}
            />
          </label>

          <div className="auth-actions">
            <button
              className="primary"
              disabled={!playerName.trim() || pendingAction === 'create'}
              onClick={createGame}
            >
              {pendingAction === 'create' ? <Loader2 className="spin" /> : <Plus />}
              방 만들기
            </button>
          </div>

          <div className="join-row">
            <label>
              방 코드
              <input
                value={joinCode}
                maxLength={8}
                placeholder="ABC123"
                onChange={(event) => setJoinCode(event.target.value.toUpperCase())}
              />
            </label>
            <button
              disabled={!playerName.trim() || !joinCode.trim() || pendingAction === 'join'}
              onClick={joinGame}
            >
              {pendingAction === 'join' ? <Loader2 className="spin" /> : <LogIn />}
              참가
            </button>
          </div>

          {error ? <p className="error-text">{error}</p> : null}
        </section>
      </main>
    );
  }

  return (
    <main className="shell game-shell">
      <header className="topbar">
        <div>
          <span className="eyebrow">방 코드</span>
          <button className="code-button" onClick={copyCode}>
            {session.code}
            <Copy size={16} />
          </button>
        </div>
        <div className="topbar-actions">
          <button onClick={() => refreshState('refresh')} disabled={pendingAction === 'refresh'}>
            {pendingAction === 'refresh' ? <Loader2 className="spin" /> : <RefreshCw />}
            새로고침
          </button>
          <button className="ghost" onClick={leaveLocalSession}>
            <DoorOpen />
            나가기
          </button>
        </div>
      </header>

      {error ? <p className="error-text">{error}</p> : null}

      {!state ? (
        <section className="loading-panel">
          <Loader2 className="spin" />
          게임 상태를 불러오는 중
        </section>
      ) : (
        <div className="game-grid">
          <section className="table-panel">
            <div className="round-header">
              <div>
                <span className="eyebrow">상태</span>
                <h2>{state.game.status === 'waiting' ? '대기실' : `라운드 ${state.round?.round_number ?? '-'}`}</h2>
              </div>
              <StatusBadge status={state.game.status} />
            </div>

            {state.game.status === 'finished' ? (
              <div className="finish-banner">
                <h3>{winner?.name ?? '승자'} 승리</h3>
                <p>새 게임은 첫 화면에서 다시 만들 수 있습니다.</p>
              </div>
            ) : null}

            {state.game.status === 'waiting' ? (
              <div className="waiting-box">
                <p>2명 이상 모이면 방장이 시작할 수 있습니다.</p>
                <button className="primary" disabled={!canStart || pendingAction === 'start'} onClick={startGame}>
                  {pendingAction === 'start' ? <Loader2 className="spin" /> : <Play />}
                  게임 시작
                </button>
              </div>
            ) : (
              <>
                <div className="current-bid-box">
                  <span className="eyebrow">현재 선언</span>
                  <strong>{currentBid ? describeBid(currentBid) : '아직 선언 없음'}</strong>
                  <p>
                    {declarer ? `${declarer.name} 선언` : '시작자가 첫 선언을 기다리는 중'} ·{' '}
                    {currentTurnPlayer ? `${currentTurnPlayer.name} 차례` : '차례 없음'}
                  </p>
                </div>

                <div className="hand-row" aria-label="내 주사위">
                  {state.own_hand.length > 0 ? (
                    state.own_hand.map((value, index) => (
                      <span className={value === 6 ? 'die wild' : 'die'} key={`${value}-${index}`}>
                        {value}
                      </span>
                    ))
                  ) : (
                    <span className="muted">내 주사위가 없습니다.</span>
                  )}
                </div>

                <div className="action-panel">
                  <label>
                    다음 선언
                    <select
                      value={selectedBid?.rank ?? ''}
                      disabled={!canBid}
                      onChange={(event) => setSelectedRank(Number(event.target.value))}
                    >
                      {bidOptions.map((option) => (
                        <option value={option.rank} key={option.rank}>
                          {option.label}
                        </option>
                      ))}
                    </select>
                  </label>
                  <button className="primary" disabled={!canBid || pendingAction === 'bid'} onClick={placeBid}>
                    {pendingAction === 'bid' ? <Loader2 className="spin" /> : <Dice5 />}
                    선언
                  </button>
                  <button
                    className="danger"
                    disabled={!canChallenge || pendingAction === 'challenge'}
                    onClick={challengeBid}
                  >
                    {pendingAction === 'challenge' ? <Loader2 className="spin" /> : <Swords />}
                    블러프
                  </button>
                </div>
              </>
            )}

            {state.last_challenge ? <ChallengeResult challenge={state.last_challenge} /> : null}
          </section>

          <aside className="side-panel">
            <section>
              <h2>플레이어</h2>
              <ul className="player-list">
                {state.players.map((player) => (
                  <li
                    className={[
                      player.id === me?.id ? 'self' : '',
                      player.is_eliminated ? 'eliminated' : '',
                      player.id === state.game.current_turn_player_id ? 'turn' : '',
                    ]
                      .filter(Boolean)
                      .join(' ')}
                    key={player.id}
                  >
                    <span>{player.name}</span>
                    <strong>{player.dice_count}개</strong>
                  </li>
                ))}
              </ul>
            </section>

            <section>
              <h2>최근 선언</h2>
              <ol className="bid-list">
                {state.latest_bids.length > 0 ? (
                  state.latest_bids.map((bid) => (
                    <li key={bid.id}>
                      <span>{bid.player_name}</span>
                      <strong>{describeBid(bid)}</strong>
                    </li>
                  ))
                ) : (
                  <li className="muted">아직 선언이 없습니다.</li>
                )}
              </ol>
            </section>
          </aside>
        </div>
      )}
    </main>
  );
}

function SetupScreen() {
  return (
    <main className="shell setup-shell">
      <section className="setup-panel">
        <Dice5 size={42} />
        <h1>Supabase 환경 변수가 필요합니다</h1>
        <p>
          `.env` 또는 Vercel 환경 변수에 `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`를 설정한 뒤 다시
          실행하세요.
        </p>
      </section>
    </main>
  );
}

function StatusBadge({ status }: { status: GameState['game']['status'] }) {
  const label = status === 'waiting' ? '대기' : status === 'playing' ? '진행 중' : '종료';
  return <span className={`status ${status}`}>{label}</span>;
}

function ChallengeResult({ challenge }: { challenge: NonNullable<GameState['last_challenge']> }) {
  return (
    <section className="challenge-panel">
      <div>
        <span className="eyebrow">최근 블러프</span>
        <h3>{outcomeLabel(challenge.outcome)}</h3>
        <p>
          제시 {challenge.claimed_quantity}개 · 실제 {challenge.actual_quantity}개 · 패널티{' '}
          {challenge.penalty}개
        </p>
      </div>
      <div className="reveal-grid">
        {challenge.revealed_hands.map((hand) => (
          <div className="reveal-hand" key={hand.player_id}>
            <strong>{hand.name}</strong>
            <div>
              {hand.dice.map((value, index) => (
                <span className={value === 6 ? 'mini-die wild' : 'mini-die'} key={`${hand.player_id}-${index}`}>
                  {value}
                </span>
              ))}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

export default App;
