const players = [
  { name: '윤주킴', dice: [1, 4, 6, 2, 3] },
  { name: '서연', dice: [4, 6, 6, 1, 5] },
  { name: '지은', dice: [2, 4, 4, 3, 6] },
  { name: '현우', dice: [5, 2, 1, 6, 4] },
];

const scenarios = [
  { declarer: '윤주킴', challenger: '서연', quantity: 8, face: 4, isSpecialStar: false },
  { declarer: '지은', challenger: '현우', quantity: 3, face: 6, isSpecialStar: true },
];

function countActual({ face, isSpecialStar }) {
  return players.reduce((sum, player) => {
    const matchingDice = player.dice.filter((value) => {
      if (isSpecialStar) {
        return value === 6;
      }

      return value === face || value === 6;
    });

    return sum + matchingDice.length;
  }, 0);
}

function resolveChallenge(scenario) {
  const actual = countActual(scenario);
  const difference = Math.abs(actual - scenario.quantity);

  if (actual < scenario.quantity) {
    return {
      ...scenario,
      actual,
      difference,
      outcome: '블러프 성공',
      loser: scenario.declarer,
    };
  }

  if (actual > scenario.quantity) {
    return {
      ...scenario,
      actual,
      difference,
      outcome: '블러프 실패',
      loser: scenario.challenger,
    };
  }

  return {
    ...scenario,
    actual,
    difference,
    outcome: '정확히 맞춤',
    loser: null,
  };
}

console.log('샘플 플레이어 주사위');
for (const player of players) {
  console.log(`- ${player.name}: ${player.dice.map((value) => (value === 6 ? '★' : value)).join(' ')}`);
}

console.log('\n판정');
for (const scenario of scenarios) {
  const result = resolveChallenge(scenario);
  const label = scenario.isSpecialStar
    ? `★ ${scenario.quantity}개`
    : `${scenario.face} 또는 ★ ${scenario.quantity}개`;
  const penalty = result.loser ? `${result.loser} 주사위 ${result.difference}개 차감` : '차감 없음';

  console.log(`- ${label}: 실제 ${result.actual}개, ${result.outcome}, ${penalty}`);
}
