export type GameStatus = 'waiting' | 'playing' | 'finished';
export type ChallengeOutcome = 'success' | 'fail' | 'exact';

export type Session = {
  gameId: string;
  code: string;
  playerId: string;
  playerToken: string;
};

export type PublicPlayer = {
  id: string;
  name: string;
  seat_index: number;
  dice_count: number;
  is_eliminated: boolean;
  is_host: boolean;
};

export type Bid = {
  id: string;
  player_id: string;
  player_name: string;
  quantity: number;
  face: number;
  is_special_six: boolean;
  rank: number;
  created_at: string;
};

export type RevealedHand = {
  player_id: string;
  name: string;
  seat_index: number;
  dice: number[];
};

export type LastChallenge = {
  id: string;
  challenger_player_id: string;
  challenger_name: string;
  declarer_player_id: string;
  declarer_name: string;
  claimed_quantity: number;
  actual_quantity: number;
  outcome: ChallengeOutcome;
  penalty: number;
  loser_player_id: string | null;
  loser_name: string | null;
  revealed_hands: RevealedHand[];
  created_at: string;
};

export type GameState = {
  game: {
    id: string;
    code: string;
    status: GameStatus;
    max_players: number;
    host_player_id: string;
    current_round_id: string | null;
    current_turn_player_id: string | null;
    winner_player_id: string | null;
  };
  me: PublicPlayer | null;
  players: PublicPlayer[];
  round: {
    id: string;
    round_number: number;
    starter_player_id: string;
    current_bid: Bid | null;
  } | null;
  own_hand: number[];
  latest_bids: Bid[];
  last_challenge: LastChallenge | null;
};

export type RpcSessionPayload = {
  game_id: string;
  code: string;
  player_id: string;
  player_token: string;
};

export type BidOption = {
  quantity: number;
  face: number;
  isSpecialSix: boolean;
  rank: number;
  label: string;
};

export const SESSION_STORAGE_KEY = 'bluff.session.v1';
export const NORMAL_FACES = [1, 2, 3, 4, 5] as const;

export function bidRank(quantity: number, face: number, isSpecialSix: boolean) {
  return isSpecialSix ? quantity * 20 + 6 : quantity * 10 + face;
}

export function describeBid(
  bid: Pick<Bid, 'quantity' | 'face' | 'is_special_six'> | BidOption,
) {
  const quantity = bid.quantity;
  const face = bid.face;
  const isSpecialSix = 'isSpecialSix' in bid ? bid.isSpecialSix : bid.is_special_six;
  return isSpecialSix ? `특수 6이 ${quantity}개` : `${face} 또는 6이 ${quantity}개`;
}

export function generateBidOptions(totalDice: number, currentRank = 0): BidOption[] {
  const options: BidOption[] = [];

  for (let quantity = 1; quantity <= totalDice; quantity += 1) {
    for (const face of NORMAL_FACES) {
      const rank = bidRank(quantity, face, false);
      if (rank > currentRank) {
        options.push({
          quantity,
          face,
          isSpecialSix: false,
          rank,
          label: `${quantity}개-${face}`,
        });
      }
    }

    if (quantity % 2 === 0) {
      const specialQuantity = quantity / 2;
      const rank = bidRank(specialQuantity, 6, true);
      if (rank > currentRank) {
        options.push({
          quantity: specialQuantity,
          face: 6,
          isSpecialSix: true,
          rank,
          label: `특수 6 ${specialQuantity}개`,
        });
      }
    }
  }

  return options.sort((a, b) => a.rank - b.rank);
}

export function loadSession(): Session | null {
  const raw = window.localStorage.getItem(SESSION_STORAGE_KEY);
  if (!raw) {
    return null;
  }

  try {
    return JSON.parse(raw) as Session;
  } catch {
    window.localStorage.removeItem(SESSION_STORAGE_KEY);
    return null;
  }
}

export function saveSession(session: Session) {
  window.localStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify(session));
}

export function clearSession() {
  window.localStorage.removeItem(SESSION_STORAGE_KEY);
}

export function outcomeLabel(outcome: ChallengeOutcome) {
  if (outcome === 'success') {
    return '블러프 성공';
  }
  if (outcome === 'fail') {
    return '블러프 실패';
  }
  return '정확히 맞춤';
}
