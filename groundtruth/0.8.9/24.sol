// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;




interface ITreasury {
    function deposit(
        address _principalToken,
        uint _principalAmount,
        uint _payoutAmount
    ) external;

    function valueOfToken(address _principalToken, uint _amount) external view returns (uint value);
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}



contract Ownable {
    event OwnerNominated(address newOwner);
    event OwnerChanged(address newOwner);

    address public owner;
    address public nominatedOwner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function nominateNewOwner(address _owner) external onlyOwner {
        nominatedOwner = _owner;
        emit OwnerNominated(_owner);
    }

    function acceptOwnership() external {
        require(msg.sender == nominatedOwner, "not nominated");

        owner = nominatedOwner;
        nominatedOwner = address(0);

        emit OwnerChanged(owner);
    }
}


library FullMath {
    function fullMul(uint x, uint y) private pure returns (uint l, uint h) {
        uint mm = mulmod(x, y, type(uint).max);
        l = x * y;
        h = mm - l;
        if (mm < l) h -= 1;
    }

    function fullDiv(
        uint l,
        uint h,
        uint d
    ) private pure returns (uint) {
        uint pow2 = d & d;
        d /= pow2;
        l /= pow2;
        l += h * ((pow2) / pow2 + 1);
        uint r = 1;
        r *= 2 - d * r;
        r *= 2 - d * r;
        r *= 2 - d * r;
        r *= 2 - d * r;
        r *= 2 - d * r;
        r *= 2 - d * r;
        r *= 2 - d * r;
        r *= 2 - d * r;
        return l * r;
    }

    function mulDiv(
        uint x,
        uint y,
        uint d
    ) internal pure returns (uint) {
        (uint l, uint h) = fullMul(x, y);
        uint mm = mulmod(x, y, d);
        if (mm > l) h -= 1;
        l -= mm;
        require(h < d, "FullMath::mulDiv: overflow");
        return fullDiv(l, h, d);
    }
}

contract Migrations {
    address public owner = msg.sender;
    uint256 public last_completed_migration;

    modifier restricted() {
        require(
            msg.sender == owner,
            "This function is restricted to the contract's owner"
        );
        _;
    }

    function setCompleted(uint256 completed) public restricted {
        last_completed_migration = completed;
    }
}

abstract contract ProtocolConstants {
    /* ========== GENERAL ========== */

    // The zero address, utility
    address internal constant _ZERO_ADDRESS = address(0);

    // One year, utility
    uint256 internal constant _ONE_YEAR = 365 days;

    // Basis Points
    uint256 internal constant _MAX_BASIS_POINTS = 100_00;

    /* ========== VADER TOKEN ========== */

    // Max VADER supply
    uint256 internal constant _INITIAL_VADER_SUPPLY = 2_500_000_000 * 1 ether;

    // Allocation for VETH holders
    uint256 internal constant _VETH_ALLOCATION = 1_000_000_000 * 1 ether;

    // Team allocation vested over {VESTING_DURATION} years
    uint256 internal constant _TEAM_ALLOCATION = 250_000_000 * 1 ether;

    // Ecosystem growth fund unlocked for partnerships & USDV provision
    uint256 internal constant _ECOSYSTEM_GROWTH = 250_000_000 * 1 ether;

    // Emission Era
    uint256 internal constant _EMISSION_ERA = 24 hours;

    // Initial Emission Curve, 5
    uint256 internal constant _INITIAL_EMISSION_CURVE = 5;

    // Fee Basis Points
    uint256 internal constant _MAX_FEE_BASIS_POINTS = 1_00;

    /* ========== VESTING ========== */

    // Vesting Duration
    uint256 internal constant _VESTING_DURATION = 2 * _ONE_YEAR;

    /* ========== CONVERTER ========== */

    // Vader -> Vether Conversion Rate (1000:1)
    uint256 internal constant _VADER_VETHER_CONVERSION_RATE = 1000;

    // Burn Address
    address internal constant _BURN =
        0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD;

    /* ========== SWAP QUEUE ========== */

    // A minimum of 10 swaps will be executed per block
    uint256 internal constant _MIN_SWAPS_EXECUTED = 10;

    // Expressed in basis points (50%)
    uint256 internal constant _DEFAULT_SWAPS_EXECUTED = 50_00;

    // The queue size of each block is 100 units
    uint256 internal constant _QUEUE_SIZE = 100;

    /* ========== GAS QUEUE ========== */

    // Address of Chainlink Fast Gas Price Oracle
    address internal constant _FAST_GAS_ORACLE =
        0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C;

    /* ========== VADER RESERVE ========== */

    // Minimum delay between grants
    uint256 internal constant _GRANT_DELAY = 30 days;

    // Maximum grant size divisor
    uint256 internal constant _MAX_GRANT_BASIS_POINTS = 10_00;
}


interface IVaderReserve {
    /* ========== STRUCTS ========== */
    /* ========== FUNCTIONS ========== */

    function reimburseImpermanentLoss(address recipient, uint256 amount)
        external;

    function grant(address recipient, uint256 amount) external;

    function reserve() external view returns (uint256);

    /* ========== EVENTS ========== */

    event GrantDistributed(address recipient, uint256 amount);
    event LossCovered(address recipient, uint256 amount, uint256 actualAmount);
}

library VaderMath {
    /* ========== CONSTANTS ========== */

    uint256 public constant ONE = 1 ether;

    /* ========== LIBRARY FUNCTIONS ========== */

    /**
     * @dev Calculates the amount of liquidity units for the {vaderDeposited}
     * and {assetDeposited} amounts across {totalPoolUnits}.
     *
     * The {vaderBalance} and {assetBalance} are taken into account in order to
     * calculate any necessary slippage adjustment.
     */
    function calculateLiquidityUnits(
        uint256 vaderDeposited,
        uint256 vaderBalance,
        uint256 assetDeposited,
        uint256 assetBalance,
        uint256 totalPoolUnits
    ) public pure returns (uint256) {
        // slipAdjustment
        uint256 slip = calculateSlipAdjustment(
            vaderDeposited,
            vaderBalance,
            assetDeposited,
            assetBalance
        );

        // (Va + vA)
        uint256 poolUnitFactor = (vaderBalance * assetDeposited) +
            (vaderDeposited * assetBalance);

        // 2VA
        uint256 denominator = ONE * 2 * vaderBalance * assetBalance;

        // P * [(Va + vA) / (2 * V * A)] * slipAdjustment
        return ((totalPoolUnits * poolUnitFactor) / denominator) * slip;
    }

    /**
    * @dev Calculates the necessary slippage adjustment for the {vaderDeposited} and {assetDeposited}
    * amounts across the total {vaderBalance} and {assetBalance} amounts.
    */
    function calculateSlipAdjustment(
        uint256 vaderDeposited,
        uint256 vaderBalance,
        uint256 assetDeposited,
        uint256 assetBalance
    ) public pure returns (uint256) {
        // Va
        uint256 vaderAsset = vaderBalance * assetDeposited;

        // aV
        uint256 assetVader = assetBalance * vaderDeposited;

        // (v + V) * (a + A)
        uint256 denominator = (vaderDeposited + vaderBalance) *
            (assetDeposited + assetBalance);

        // 1 - [|Va - aV| / (v + V) * (a + A)]
        return ONE - (delta(vaderAsset, assetVader) / denominator);
    }

    /**
    * @dev Calculates the loss based on the supplied {releasedVader} and {releasedAsset}
    * compared to the supplied {originalVader} and {originalAsset}.
    */
    function calculateLoss(
        uint256 originalVader,
        uint256 originalAsset,
        uint256 releasedVader,
        uint256 releasedAsset
    ) public pure returns (uint256 loss) {
        //
        // TODO: Vader Formula Differs https://github.com/vetherasset/vaderprotocol-contracts/blob/main/contracts/Utils.sol#L347-L356
        //

        // [(A0 * P1) + V0]
        uint256 originalValue = ((originalAsset * releasedVader) /
            releasedAsset) + originalVader;

        // [(A1 * P1) + V1]
        uint256 releasedValue = ((releasedAsset * releasedVader) /
            releasedAsset) + releasedVader;

        // [(A0 * P1) + V0] - [(A1 * P1) + V1]
        if (originalValue > releasedValue) loss = originalValue - releasedValue;
    }

    /**
    * @dev Calculates the {amountOut} of the swap based on the supplied {amountIn}
    * across the supplied {reserveIn} and {reserveOut} amounts.
    */
    function calculateSwap(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        // x * Y * X
        uint256 numerator = amountIn * reserveIn * reserveOut;

        // (x + X) ^ 2
        uint256 denominator = pow(amountIn + reserveIn);

        amountOut = numerator / denominator;
    }

    /**
    * @dev Calculates the {amountIn} of the swap based on the supplied {amountOut}
    * across the supplied {reserveIn} and {reserveOut} amounts.
    */
    function calculateSwapReverse(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountIn) {
        // X * Y
        uint256 XY = reserveIn * reserveOut;

        // 2y
        uint256 y2 = amountOut * 2;

        // 4y
        uint256 y4 = y2 * 2;

        require(
            y4 < reserveOut,
            "VaderMath::calculateSwapReverse: Desired Output Exceeds Maximum Output Possible (1/4 of Liquidity Pool)"
        );

        // root(-X^2 * Y * (4y - Y))    =>    root(X^2 * Y * (Y - 4y)) as Y - 4y >= 0    =>    Y >= 4y holds true
        uint256 numeratorA = root(XY) * root(reserveIn * (reserveOut - y4));

        // X * (2y - Y)    =>    2yX - XY
        uint256 numeratorB = y2 * reserveIn;
        uint256 numeratorC = XY;

        // -1 * (root(-X^2 * Y * (4y - Y)) + (X * (2y - Y)))    =>    -1 * (root(X^2 * Y * (Y - 4y)) + 2yX - XY)    =>    XY - root(X^2 * Y * (Y - 4y) - 2yX
        uint256 numerator = numeratorC - numeratorA - numeratorB;

        // 2y
        uint256 denominator = y2;

        amountIn = numerator / denominator;
    }

    /**
    * @dev Calculates the difference between the supplied {a} and {b} values as a positive number.
    */
    function delta(uint256 a, uint256 b) public pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /**
    * @dev Calculates the power of 2 of the supplied {a} value.
    */
    function pow(uint256 a) public pure returns (uint256) {
        return a * a;
    }

    /**
    * @dev Calculates the square root {c} of the supplied {a} value utilizing the Babylonian method:
    * https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method
    */
    function root(uint256 a) public pure returns (uint256 c) {
        if (a > 3) {
            c = a;
            uint256 x = a / 2 + 1;
            while (x < c) {
                c = x;
                x = (a / x + x) / 2;
            }
        } else if (a != 0) {
            c = 1;
        }
    }
}

interface IAggregator {
    function latestAnswer() external view returns (int256);
}


interface ISwapQueue {
    /* ========== STRUCTS ========== */

    struct Node {
        uint256 value;
        uint256 previous;
        uint256 next;
    }

    struct Queue {
        mapping(uint256 => Node) linkedList;
        uint256 start;
        uint256 end;
        uint256 size;
    }

    /* ========== FUNCTIONS ========== */
    /* ========== EVENTS ========== */
}

interface IBasePool {
    /* ========== STRUCTS ========== */

    struct Position {
        uint256 creation;
        uint256 liquidity;
        uint256 originalNative;
        uint256 originalForeign;
    }

    /* ========== FUNCTIONS ========== */

    function swap(
        uint256 nativeAmountIn,
        uint256 foreignAmountIn,
        address to
    ) external returns (uint256);

    function swap(
        uint256 nativeAmountIn,
        uint256 foreignAmountIn,
        address to,
        bytes calldata
    ) external returns (uint256);

    function mint(address to) external returns (uint256 liquidity);

    function getReserves() external view returns (
            uint112 reserveNative,
            uint112 reserveForeign,
            uint32 blockTimestampLast
        );

    /* ========== EVENTS ========== */

    event Mint(
        address indexed sender,
        address indexed to,
        uint256 amount0,
        uint256 amount1
    ); // Adjustment -> new argument to which didnt exist
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint256 reserve0, uint256 reserve1); // Adjustment -> 112 to 256
    event PositionOpened(address indexed sender, uint256 id, uint256 liquidity);
    event PositionClosed(
        address indexed sender,
        uint256 id,
        uint256 liquidity,
        uint256 loss
    );
}


library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}

interface IStakingRewards {
    // Views

    function balanceOf(address account) external view returns (uint);

    function earned(address account) external view returns (uint);

    function getRewardForDuration() external view returns (uint);

    function lastTimeRewardApplicable() external view returns (uint);

    function rewardPerToken() external view returns (uint);

    // function rewardsDistribution() external view returns (address);

    // function rewardsToken() external view returns (address);

    function totalSupply() external view returns (uint);

    // Mutative

    function exit() external;

    function getReward() external;

    function stake(uint amount) external;

    function withdraw(uint amount) external;
}

  
contract Owned {
    address public owner;
    address public nominatedOwner;

    constructor(address _owner) {
        require(_owner != address(0), "Owner address cannot be 0");
        owner = _owner;
        emit OwnerChanged(address(0), _owner);
    }

    function nominateNewOwner(address _owner) external onlyOwner {
        nominatedOwner = _owner;
        emit OwnerNominated(_owner);
    }

    function acceptOwnership() external {
        require(msg.sender == nominatedOwner, "You must be nominated before you can accept ownership");
        emit OwnerChanged(owner, nominatedOwner);
        owner = nominatedOwner;
        nominatedOwner = address(0);
    }

    modifier onlyOwner {
        _onlyOwner();
        _;
    }

    function _onlyOwner() private view {
        require(msg.sender == owner, "Only the contract owner may perform this action");
    }

    event OwnerNominated(address newOwner);
    event OwnerChanged(address oldOwner, address newOwner);
}
interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}

interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

library Math {
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

interface IUniswapV2ERC20 {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

library Babylonian {
    // credit for this implementation goes to
    // https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMath64x64.sol#L687
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        // this block is equivalent to r = uint256(1) << (BitMath.mostSignificantBit(x) / 2);
        // however that code costs significantly more gas
        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1; // Seven iterations should be enough
        uint256 r1 = x / r;
        return (r < r1 ? r : r1);
    }
}

library BitMath {
    // returns the 0 indexed position of the most significant bit of the input x
    // s.t. x >= 2**msb and x < 2**(msb+1)
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0, "BitMath::mostSignificantBit: zero");

        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            r += 128;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            r += 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            r += 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            r += 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            r += 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            r += 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            r += 2;
        }
        if (x >= 0x2) r += 1;
    }

    // returns the 0 indexed position of the least significant bit of the input x
    // s.t. (x & 2**lsb) != 0 and (x & (2**(lsb) - 1)) == 0)
    // i.e. the bit at the index is set and the mask of all lower bits is 0
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0, "BitMath::leastSignificantBit: zero");

        r = 255;
        if (x & type(uint128).max > 0) {
            r -= 128;
        } else {
            x >>= 128;
        }
        if (x & type(uint64).max > 0) {
            r -= 64;
        } else {
            x >>= 64;
        }
        if (x & type(uint32).max > 0) {
            r -= 32;
        } else {
            x >>= 32;
        }
        if (x & type(uint16).max > 0) {
            r -= 16;
        } else {
            x >>= 16;
        }
        if (x & type(uint8).max > 0) {
            r -= 8;
        } else {
            x >>= 8;
        }
        if (x & 0xf > 0) {
            r -= 4;
        } else {
            x >>= 4;
        }
        if (x & 0x3 > 0) {
            r -= 2;
        } else {
            x >>= 2;
        }
        if (x & 0x1 > 0) r -= 1;
    }
}

interface AggregatorV3Interface {

  function decimals()
    external
    view
    returns (
      uint8
    );

  function description()
    external
    view
    returns (
      string memory
    );

  function version()
    external
    view
    returns (
      uint256
    );

  // getRoundData and latestRoundData should both raise "No data present"
  // if they do not have data to report, instead of returning unset values
  // which could be misinterpreted as actual reported values.
  function getRoundData(
    uint80 _roundId
  )
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

}
interface ITimelock {
    function delay() external view returns (uint256);

    function GRACE_PERIOD() external pure returns (uint256);

    function acceptAdmin() external;

    function queuedTransactions(bytes32 hash) external view returns (bool);

    function queueTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external returns (bytes32);

    function cancelTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external;

    function executeTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external payable returns (bytes memory);
}

interface IGasQueue {
    /* ========== STRUCTS ========== */
    /* ========== FUNCTIONS ========== */
    /* ========== EVENTS ========== */
}


interface IUSDV {
    /* ========== STRUCTS ========== */

    /* ========== FUNCTIONS ========== */

    function distributeEmission() external;

    /* ========== EVENTS ========== */
}

interface IVader {
    /* ========== FUNCTIONS ========== */

    function createEmission(address user, uint256 amount) external;

    function calculateFee() external view returns (uint256 basisPoints);

    function getCurrentEraEmission() external view returns (uint256);

    function getEraEmission(uint256 currentSupply)
        external
        view
        returns (uint256);

    /* ========== EVENTS ========== */

    event Emission(address to, uint256 amount);

    event EmissionChanged(uint256 previous, uint256 next);

    event MaxSupplyChanged(uint256 previous, uint256 next);

    event GrantClaimed(address indexed beneficiary, uint256 amount);

    event ProtocolInitialized(
        address converter,
        address vest,
        address usdv,
        address dao
    );
}

interface IConverter {
    /* ========== FUNCTIONS ========== */

    function convert(bytes32[] calldata proof, uint256 amount)
        external
        returns (uint256 vaderReceived);

    /* ========== EVENTS ========== */

    event Conversion(
        address indexed user,
        uint256 vetherAmount,
        uint256 vaderAmount
    );
}

interface ILinearVesting {
    /* ========== STRUCTS ========== */

    // Struct of a vesting member, tight-packed to 256-bits
    struct Vester {
        uint192 amount;
        uint64 lastClaim;
        uint128 start;
        uint128 end;
    }

    /* ========== FUNCTIONS ========== */

    function getClaim() external view returns (uint256 vestedAmount);

    function claim() external returns (uint256 vestedAmount);

    function claimConverted() external returns (uint256 vestedAmount);

    function begin() external;

    function vestFor(address user, uint256 amount) external;

    /* ========== EVENTS ========== */

    event VestingInitialized(uint256 duration);

    event Vested(address indexed from, uint256 amount);
}

interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
interface IXVader is IERC20 {
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);

    function getPastTotalSupply(uint256 blockNumber) external view returns (uint256);
}
interface IVaderRouter {
    /* ========== STRUCTS ========== */
    /* ========== FUNCTIONS ========== */

    function addLiquidity(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256, // amountAMin = unused
        uint256, // amountBMin = unused
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidity(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 id,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    /* ========== EVENTS ========== */
}

interface IVaderRouterV2 {
    /* ========== STRUCTS ========== */
    /* ========== FUNCTIONS ========== */

    function addLiquidity(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256, // amountAMin = unused
        uint256, // amountBMin = unused
        address to,
        uint256 deadline
    ) external returns (uint256 liquidity);

    function addLiquidity(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        address to,
        uint256 deadline
    ) external returns (uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 id,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        IERC20[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    /* ========== EVENTS ========== */
}

interface ISynth is IERC20 {
    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;
}

interface IBasePoolV2 {
    /* ========== STRUCTS ========== */

    struct Position {
        IERC20 foreignAsset;
        uint256 creation;
        uint256 liquidity;
        uint256 originalNative;
        uint256 originalForeign;
    }

    struct PairInfo {
        uint256 totalSupply;
        uint112 reserveNative;
        uint112 reserveForeign;
        uint32 blockTimestampLast;
        PriceCumulative priceCumulative;
    }

    struct PriceCumulative {
        uint256 nativeLast;
        uint256 foreignLast;
    }

    /* ========== FUNCTIONS ========== */

    function getReserves(
        IERC20 foreignAsset
    ) external view returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast
    );

    function nativeAsset() external view returns (IERC20);

    function supported(IERC20 token) external view returns (bool);

    function positionForeignAsset(uint256 id) external view returns (IERC20);

    function pairSupply(IERC20 foreignAsset) external view returns (uint256);

    function doubleSwap(
        IERC20 foreignAssetA,
        IERC20 foreignAssetB,
        uint256 foreignAmountIn,
        address to
    ) external returns (uint256);

    function swap(
        IERC20 foreignAsset,
        uint256 nativeAmountIn,
        uint256 foreignAmountIn,
        address to
    ) external returns (uint256);

    function mint(
        IERC20 foreignAsset,
        uint256 nativeDeposit,
        uint256 foreignDeposit,
        address from,
        address to
    ) external returns (uint256 liquidity);

    /* ========== EVENTS ========== */

    event Mint(
        address indexed sender,
        address indexed to,
        uint256 amount0,
        uint256 amount1
    ); // Adjustment -> new argument to which didnt exist
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        IERC20 foreignAsset,
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(IERC20 foreignAsset, uint256 reserve0, uint256 reserve1); // Adjustment -> 112 to 256
    event PositionOpened(
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 liquidity
    );
    event PositionClosed(
        address indexed sender,
        uint256 id,
        uint256 liquidity,
        uint256 loss
    );
}

interface IERC20Extended is IERC20 {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;
}

library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}
library SafeERC20 {
    using Address for address;

    function safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            uint256 newAllowance = oldAllowance - value;
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the substraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b <= a, errorMessage);
            return a - b;
        }
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a / b;
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a % b;
        }
    }
}
contract Treasury is Ownable, ITreasury {
    using SafeERC20 for IERC20;
    using SafeMath for uint;

    event SetBondContract(address bond, bool approved);
    event Withdraw(address indexed token, address indexed destination, uint amount);

    uint8 private immutable PAYOUT_TOKEN_DECIMALS;
    uint private immutable PAYOUT_TOKEN_SCALE; // 10 ** decimals

    address public immutable payoutToken;
    mapping(address => bool) public isBondContract;

    constructor(address _payoutToken) {
        require(_payoutToken != address(0), "payout token = zero");
        payoutToken = _payoutToken;
        uint8 decimals = IERC20Metadata(_payoutToken).decimals();
        PAYOUT_TOKEN_DECIMALS = decimals;
        PAYOUT_TOKEN_SCALE = 10**decimals;
    }

    modifier onlyBondContract() {
        require(isBondContract[msg.sender], "not bond");
        _;
    }

    /**
     *  @notice deposit principal token and recieve back payout token
     *  @param _principalToken address
     *  @param _principalAmount uint
     *  @param _payoutAmount uint
     */
    function deposit(
        address _principalToken,
        uint _principalAmount,
        uint _payoutAmount
    ) external override onlyBondContract {
        IERC20(_principalToken).safeTransferFrom(msg.sender, address(this), _principalAmount);
        IERC20(payoutToken).safeTransfer(msg.sender, _payoutAmount);
    }

    /**
     *   @notice returns payout token valuation of priciple
     *   @param _principalToken address
     *   @param _amount uint
     *   @return value uint
     */
    function valueOfToken(address _principalToken, uint _amount) external view override returns (uint) {
        // convert amount to match payout token decimals
        return _amount.mul(PAYOUT_TOKEN_SCALE).div(10**IERC20Metadata(_principalToken).decimals());
    }

    /**
     *  @notice owner can withdraw ERC20 token to desired address
     *  @param _token uint
     *  @param _destination address
     *  @param _amount uint
     */
    function withdraw(
        address _token,
        address _destination,
        uint _amount
    ) external onlyOwner {
        IERC20(_token).safeTransfer(_destination, _amount);
        emit Withdraw(_token, _destination, _amount);
    }

    /**
     *  @notice set bond contract
     *  @param _bond address
     *  @param _approve bool
     */
    function setBondContract(address _bond, bool _approve) external onlyOwner {
        require(isBondContract[_bond] != _approve, "no change");
        isBondContract[_bond] = _approve;
        emit SetBondContract(_bond, _approve);
    }
}


abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}
contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        unchecked {
            _approve(sender, _msgSender(), currentAllowance - amount);
        }

        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `sender` to `recipient`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[sender] = senderBalance - amount;
        }
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);

        _afterTokenTransfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
}
contract TestToken is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) ERC20(name, symbol) {
        // _setupDecimals(decimals);
    }

    function mint(address _to, uint _amount) external {
        _mint(_to, _amount);
    }

    function burn(address _from, uint _amount) external {
        _burn(_from, _amount);
    }
}

library FixedPoint {
    struct uq112x112 {
        uint224 _x;
    }

    struct uq144x112 {
        uint _x;
    }

    uint8 private constant RESOLUTION = 112;
    uint private constant Q112 = 0x10000000000000000000000000000;
    uint private constant Q224 = 0x100000000000000000000000000000000000000000000000000000000;
    uint private constant LOWER_MASK = 0xffffffffffffffffffffffffffff; // decimal of UQ*x112 (lower 112 bits)

    function decode(uq112x112 memory self) internal pure returns (uint112) {
        return uint112(self._x >> RESOLUTION);
    }

    // decode a uq112x112 into a uint with 18 decimals of precision
    function decode112with18(uq112x112 memory self) internal pure returns (uint) {
        return uint(self._x) / 5192296858534827;
    }

    function fraction(uint numerator, uint denominator) internal pure returns (uq112x112 memory) {
        require(denominator > 0, "FixedPoint::fraction: division by zero");
        if (numerator == 0) return FixedPoint.uq112x112(0);

        if (numerator <= type(uint144).max) {
            uint result = (numerator << RESOLUTION) / denominator;
            require(result <= type(uint224).max, "FixedPoint::fraction: overflow");
            return uq112x112(uint224(result));
        } else {
            uint result = FullMath.mulDiv(numerator, Q112, denominator);
            require(result <= type(uint224).max, "FixedPoint::fraction: overflow");
            return uq112x112(uint224(result));
        }
    }
}
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS,
        InvalidSignatureV
    }

    function _throwError(RecoverError error) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert("ECDSA: invalid signature");
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert("ECDSA: invalid signature length");
        } else if (error == RecoverError.InvalidSignatureS) {
            revert("ECDSA: invalid signature 's' value");
        } else if (error == RecoverError.InvalidSignatureV) {
            revert("ECDSA: invalid signature 'v' value");
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature` or error string. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     *
     * _Available since v4.3._
     */
    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError) {
        // Check the signature length
        // - case 65: r,s,v signature (standard)
        // - case 64: r,vs signature (cf https://eips.ethereum.org/EIPS/eip-2098) _Available since v4.1._
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else if (signature.length == 64) {
            bytes32 r;
            bytes32 vs;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            assembly {
                r := mload(add(signature, 0x20))
                vs := mload(add(signature, 0x40))
            }
            return tryRecover(hash, r, vs);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength);
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, signature);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[EIP-2098 short signatures]
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address, RecoverError) {
        bytes32 s;
        uint8 v;
        assembly {
            s := and(vs, 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            v := add(shr(255, vs), 27)
        }
        return tryRecover(hash, v, r, s);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     *
     * _Available since v4.2._
     */
    function recover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, r, vs);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address, RecoverError) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS);
        }
        if (v != 27 && v != 28) {
            return (address(0), RecoverError.InvalidSignatureV);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature);
        }

        return (signer, RecoverError.NoError);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, v, r, s);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from a `hash`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /**
     * @dev Returns an Ethereum Signed Typed Data, created from a
     * `domainSeparator` and a `structHash`. This produces hash corresponding
     * to the one signed with the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`]
     * JSON-RPC method as part of EIP-712.
     *
     * See {recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
abstract contract EIP712 {
    /* solhint-disable var-name-mixedcase */
    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    bytes32 private immutable _TYPE_HASH;

    /* solhint-enable var-name-mixedcase */

    /**
     * @dev Initializes the domain separator and parameter caches.
     *
     * The meaning of `name` and `version` is specified in
     * https://eips.ethereum.org/EIPS/eip-712#definition-of-domainseparator[EIP 712]:
     *
     * - `name`: the user readable name of the signing domain, i.e. the name of the DApp or the protocol.
     * - `version`: the current major version of the signing domain.
     *
     * NOTE: These parameters cannot be changed except through a xref:learn::upgrading-smart-contracts.adoc[smart
     * contract upgrade].
     */
    constructor(string memory name, string memory version) {
        bytes32 hashedName = keccak256(bytes(name));
        bytes32 hashedVersion = keccak256(bytes(version));
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(typeHash, hashedName, hashedVersion);
        _TYPE_HASH = typeHash;
    }

    /**
     * @dev Returns the domain separator for the current chain.
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function _buildDomainSeparator(
        bytes32 typeHash,
        bytes32 nameHash,
        bytes32 versionHash
    ) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
    }

    /**
     * @dev Given an already https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct[hashed struct], this
     * function returns the hash of the fully encoded EIP712 message for this domain.
     *
     * This hash can be used together with {ECDSA-recover} to obtain the signer of a message. For example:
     *
     * ```solidity
     * bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
     *     keccak256("Mail(address to,string contents)"),
     *     mailTo,
     *     keccak256(bytes(mailContents))
     * )));
     * address signer = ECDSA.recover(digest, signature);
     * ```
     */
    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        return ECDSA.toTypedDataHash(_domainSeparatorV4(), structHash);
    }
}

library Counters {
    struct Counter {
        // This variable should never be directly accessed by users of the library: interactions must be restricted to
        // the library's function. As of Solidity v0.5.2, this cannot be enforced, though there is a proposal to add
        // this feature: see https://github.com/ethereum/solidity/issues/4637
        uint256 _value; // default: 0
    }

    function current(Counter storage counter) internal view returns (uint256) {
        return counter._value;
    }

    function increment(Counter storage counter) internal {
        unchecked {
            counter._value += 1;
        }
    }

    function decrement(Counter storage counter) internal {
        uint256 value = counter._value;
        require(value > 0, "Counter: decrement overflow");
        unchecked {
            counter._value = value - 1;
        }
    }

    function reset(Counter storage counter) internal {
        counter._value = 0;
    }
}
abstract contract ERC20Permit is ERC20, IERC20Permit, EIP712 {
    using Counters for Counters.Counter;

    mapping(address => Counters.Counter) private _nonces;

    // solhint-disable-next-line var-name-mixedcase
    bytes32 private immutable _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /**
     * @dev Initializes the {EIP712} domain separator using the `name` parameter, and setting `version` to `"1"`.
     *
     * It's a good idea to use the same `name` that is defined as the ERC20 token name.
     */
    constructor(string memory name) EIP712(name, "1") {}

    /**
     * @dev See {IERC20Permit-permit}.
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual override {
        require(block.timestamp <= deadline, "ERC20Permit: expired deadline");

        bytes32 structHash = keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, v, r, s);
        require(signer == owner, "ERC20Permit: invalid signature");

        _approve(owner, spender, value);
    }

    /**
     * @dev See {IERC20Permit-nonces}.
     */
    function nonces(address owner) public view virtual override returns (uint256) {
        return _nonces[owner].current();
    }

    /**
     * @dev See {IERC20Permit-DOMAIN_SEPARATOR}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @dev "Consume a nonce": return the current value and increment.
     *
     * _Available since v4.1._
     */
    function _useNonce(address owner) internal virtual returns (uint256 current) {
        Counters.Counter storage nonce = _nonces[owner];
        current = nonce.current();
        nonce.increment();
    }
}
library SafeCast {
    /**
     * @dev Returns the downcasted uint224 from uint256, reverting on
     * overflow (when the input is greater than largest uint224).
     *
     * Counterpart to Solidity's `uint224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toUint224(uint256 value) internal pure returns (uint224) {
        require(value <= type(uint224).max, "SafeCast: value doesn't fit in 224 bits");
        return uint224(value);
    }

    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: value doesn't fit in 128 bits");
        return uint128(value);
    }

    /**
     * @dev Returns the downcasted uint96 from uint256, reverting on
     * overflow (when the input is greater than largest uint96).
     *
     * Counterpart to Solidity's `uint96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toUint96(uint256 value) internal pure returns (uint96) {
        require(value <= type(uint96).max, "SafeCast: value doesn't fit in 96 bits");
        return uint96(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "SafeCast: value doesn't fit in 64 bits");
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        require(value <= type(uint32).max, "SafeCast: value doesn't fit in 32 bits");
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "SafeCast: value doesn't fit in 16 bits");
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits.
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        require(value <= type(uint8).max, "SafeCast: value doesn't fit in 8 bits");
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "SafeCast: value must be positive");
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     *
     * _Available since v3.1._
     */
    function toInt128(int256 value) internal pure returns (int128) {
        require(value >= type(int128).min && value <= type(int128).max, "SafeCast: value doesn't fit in 128 bits");
        return int128(value);
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     *
     * _Available since v3.1._
     */
    function toInt64(int256 value) internal pure returns (int64) {
        require(value >= type(int64).min && value <= type(int64).max, "SafeCast: value doesn't fit in 64 bits");
        return int64(value);
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     *
     * _Available since v3.1._
     */
    function toInt32(int256 value) internal pure returns (int32) {
        require(value >= type(int32).min && value <= type(int32).max, "SafeCast: value doesn't fit in 32 bits");
        return int32(value);
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     *
     * _Available since v3.1._
     */
    function toInt16(int256 value) internal pure returns (int16) {
        require(value >= type(int16).min && value <= type(int16).max, "SafeCast: value doesn't fit in 16 bits");
        return int16(value);
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits.
     *
     * _Available since v3.1._
     */
    function toInt8(int256 value) internal pure returns (int8) {
        require(value >= type(int8).min && value <= type(int8).max, "SafeCast: value doesn't fit in 8 bits");
        return int8(value);
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        require(value <= uint256(type(int256).max), "SafeCast: value doesn't fit in an int256");
        return int256(value);
    }
}
abstract contract ERC20Votes is ERC20Permit {
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    bytes32 private constant _DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    mapping(address => address) private _delegates;
    mapping(address => Checkpoint[]) private _checkpoints;
    Checkpoint[] private _totalSupplyCheckpoints;

    /**
     * @dev Emitted when an account changes their delegate.
     */
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /**
     * @dev Emitted when a token transfer or delegate change results in changes to an account's voting power.
     */
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    /**
     * @dev Get the `pos`-th checkpoint for `account`.
     */
    function checkpoints(address account, uint32 pos) public view virtual returns (Checkpoint memory) {
        return _checkpoints[account][pos];
    }

    /**
     * @dev Get number of checkpoints for `account`.
     */
    function numCheckpoints(address account) public view virtual returns (uint32) {
        return SafeCast.toUint32(_checkpoints[account].length);
    }

    /**
     * @dev Get the address `account` is currently delegating to.
     */
    function delegates(address account) public view virtual returns (address) {
        return _delegates[account];
    }

    /**
     * @dev Gets the current votes balance for `account`
     */
    function getVotes(address account) public view returns (uint256) {
        uint256 pos = _checkpoints[account].length;
        return pos == 0 ? 0 : _checkpoints[account][pos - 1].votes;
    }

    /**
     * @dev Retrieve the number of votes for `account` at the end of `blockNumber`.
     *
     * Requirements:
     *
     * - `blockNumber` must have been already mined
     */
    function getPastVotes(address account, uint256 blockNumber) public view returns (uint256) {
        require(blockNumber < block.number, "ERC20Votes: block not yet mined");
        return _checkpointsLookup(_checkpoints[account], blockNumber);
    }

    /**
     * @dev Retrieve the `totalSupply` at the end of `blockNumber`. Note, this value is the sum of all balances.
     * It is but NOT the sum of all the delegated votes!
     *
     * Requirements:
     *
     * - `blockNumber` must have been already mined
     */
    function getPastTotalSupply(uint256 blockNumber) public view returns (uint256) {
        require(blockNumber < block.number, "ERC20Votes: block not yet mined");
        return _checkpointsLookup(_totalSupplyCheckpoints, blockNumber);
    }

    /**
     * @dev Lookup a value in a list of (sorted) checkpoints.
     */
    function _checkpointsLookup(Checkpoint[] storage ckpts, uint256 blockNumber) private view returns (uint256) {
        // We run a binary search to look for the earliest checkpoint taken after `blockNumber`.
        //
        // During the loop, the index of the wanted checkpoint remains in the range [low-1, high).
        // With each iteration, either `low` or `high` is moved towards the middle of the range to maintain the invariant.
        // - If the middle checkpoint is after `blockNumber`, we look in [low, mid)
        // - If the middle checkpoint is before or equal to `blockNumber`, we look in [mid+1, high)
        // Once we reach a single value (when low == high), we've found the right checkpoint at the index high-1, if not
        // out of bounds (in which case we're looking too far in the past and the result is 0).
        // Note that if the latest checkpoint available is exactly for `blockNumber`, we end up with an index that is
        // past the end of the array, so we technically don't find a checkpoint after `blockNumber`, but it works out
        // the same.
        uint256 high = ckpts.length;
        uint256 low = 0;
        while (low < high) {
            uint256 mid = (low+high)/2;
            if (ckpts[mid].fromBlock > blockNumber) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return high == 0 ? 0 : ckpts[high - 1].votes;
    }

    /**
     * @dev Delegate votes from the sender to `delegatee`.
     */
    function delegate(address delegatee) public virtual {
        return _delegate(_msgSender(), delegatee);
    }

    /**
     * @dev Delegates votes from signer to `delegatee`
     */
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        require(block.timestamp <= expiry, "ERC20Votes: signature expired");
        address signer = ECDSA.recover(
            _hashTypedDataV4(keccak256(abi.encode(_DELEGATION_TYPEHASH, delegatee, nonce, expiry))),
            v,
            r,
            s
        );
        require(nonce == _useNonce(signer), "ERC20Votes: invalid nonce");
        return _delegate(signer, delegatee);
    }

    /**
     * @dev Maximum token supply. Defaults to `type(uint224).max` (2^224^ - 1).
     */
    function _maxSupply() internal view virtual returns (uint224) {
        return type(uint224).max;
    }

    /**
     * @dev Snapshots the totalSupply after it has been increased.
     */
    function _mint(address account, uint256 amount) internal virtual override {
        super._mint(account, amount);
        require(totalSupply() <= _maxSupply(), "ERC20Votes: total supply risks overflowing votes");

        _writeCheckpoint(_totalSupplyCheckpoints, _add, amount);
    }

    /**
     * @dev Snapshots the totalSupply after it has been decreased.
     */
    function _burn(address account, uint256 amount) internal virtual override {
        super._burn(account, amount);

        _writeCheckpoint(_totalSupplyCheckpoints, _subtract, amount);
    }

    /**
     * @dev Move voting power when tokens are transferred.
     *
     * Emits a {DelegateVotesChanged} event.
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._afterTokenTransfer(from, to, amount);

        _moveVotingPower(delegates(from), delegates(to), amount);
    }

    /**
     * @dev Change delegation for `delegator` to `delegatee`.
     *
     * Emits events {DelegateChanged} and {DelegateVotesChanged}.
     */
    function _delegate(address delegator, address delegatee) internal virtual {
        address currentDelegate = delegates(delegator);
        uint256 delegatorBalance = balanceOf(delegator);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveVotingPower(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveVotingPower(
        address src,
        address dst,
        uint256 amount
    ) private {
        if (src != dst && amount > 0) {
            if (src != address(0)) {
                (uint256 oldWeight, uint256 newWeight) = _writeCheckpoint(_checkpoints[src], _subtract, amount);
                emit DelegateVotesChanged(src, oldWeight, newWeight);
            }

            if (dst != address(0)) {
                (uint256 oldWeight, uint256 newWeight) = _writeCheckpoint(_checkpoints[dst], _add, amount);
                emit DelegateVotesChanged(dst, oldWeight, newWeight);
            }
        }
    }

    function _writeCheckpoint(
        Checkpoint[] storage ckpts,
        function(uint256, uint256) view returns (uint256) op,
        uint256 delta
    ) private returns (uint256 oldWeight, uint256 newWeight) {
        uint256 pos = ckpts.length;
        oldWeight = pos == 0 ? 0 : ckpts[pos - 1].votes;
        newWeight = op(oldWeight, delta);

        if (pos > 0 && ckpts[pos - 1].fromBlock == block.number) {
            ckpts[pos - 1].votes = SafeCast.toUint224(newWeight);
        } else {
            ckpts.push(Checkpoint({fromBlock: SafeCast.toUint32(block.number), votes: SafeCast.toUint224(newWeight)}));
        }
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256) {
        return a + b;
    }

    function _subtract(uint256 a, uint256 b) private pure returns (uint256) {
        return a - b;
    }
}
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}
contract XVader is ProtocolConstants, ERC20Votes, ReentrancyGuard {
    // Address of vader token
    IERC20 public immutable vader;

    /*
     * @dev Initializes contract's state by setting vader's tokens address and
     * setting current token's name and symbol.
     **/
    constructor(IERC20 _vader)
        ERC20Permit("XVader")
        ERC20("XVader", "xVADER")
    {
        require(
            _vader != IERC20(_ZERO_ADDRESS),
            "XVader::constructor: _vader cannot be a zero address"
        );
        vader = _vader;
    }

    // Locks vader and mints xVader
    function enter(uint256 _amount) external nonReentrant {
        // Gets the amount of vader locked in the contract
        uint256 totalVader = vader.balanceOf(address(this));
        // Gets the amount of xVader in existence
        uint256 totalShares = totalSupply();

        uint256 xVADERToMint = totalShares == 0 || totalVader == 0
            // If no xVader exists, mint it 1:1 to the amount put in
            ? _amount
            // Calculate and mint the amount of xVader the vader is worth.
            // The ratio will change overtime, as xVader is burned/minted and
            // vader deposited + gained from fees / withdrawn.
            : (_amount * totalShares) / totalVader;

        _mint(msg.sender, xVADERToMint);

        // Lock the vader in the contract
        vader.transferFrom(msg.sender, address(this), _amount);
    }

    // Claim back your VADER
    // Unlocks the staked + gained vader and burns xVader
    function leave(uint256 _shares) external nonReentrant {
        // Calculates the amount of vader the xVader is worth
        uint vaderAmount = (_shares * vader.balanceOf(address(this))) / totalSupply();

        _burn(msg.sender, _shares);
        vader.transfer(msg.sender, vaderAmount);
    }
}
contract VaderReserve is IVaderReserve, ProtocolConstants, Ownable {
    /* ========== LIBRARIES ========== */

    // Used for safe VADER transfers
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // The Vader token the reserve is handling
    IERC20 public immutable vader;

    // Router address for IL awards
    address public router;

    // Tracks last grant time for throttling
    uint256 public lastGrant;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        IERC20 _vader
    ) {
        require(
            _vader != IERC20(_ZERO_ADDRESS),
            "VaderReserve::constructor: Incorrect Arguments"
        );
        vader = _vader;
    }

    /* ========== VIEWS ========== */

    function reserve() public view override returns (uint256) {
        return vader.balanceOf(address(this));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function grant(address recipient, uint256 amount)
        external
        override
        onlyOwner
        throttle
    {
        amount = _min(
            (reserve() * _MAX_GRANT_BASIS_POINTS) / _MAX_BASIS_POINTS,
            amount
        );
        vader.safeTransfer(recipient, amount);

        emit GrantDistributed(recipient, amount);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function initialize(address _router, address _dao) external onlyOwner {
         require(
            _router != _ZERO_ADDRESS &&
                _dao != _ZERO_ADDRESS,
            "VaderReserve::initialize: Incorrect Arguments"
        );
        router = _router;
        // transferOwnership(_dao);
    }

    function reimburseImpermanentLoss(address recipient, uint256 amount)
        external
        override
    {
        require(
            msg.sender == router,
            "VaderReserve::reimburseImpermanentLoss: Insufficient Priviledges"
        );

        uint256 actualAmount = _min(reserve(), amount);

        vader.safeTransfer(recipient, actualAmount);

        emit LossCovered(recipient, amount, actualAmount);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== PRIVATE FUNCTIONS ========== */

    /**
     * @dev Calculates the minimum of the two values
     */
    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /* ========== MODIFIERS ========== */

    modifier throttle() {
        require(
            lastGrant + _GRANT_DELAY <= block.timestamp,
            "VaderReserve::throttle: Grant Too Fast"
        );
        lastGrant = block.timestamp;
        _;
    }
}

contract GasThrottle is ProtocolConstants {
    modifier validateGas() {
        // TODO: Uncomment prior to launch
        // require(
        //     block.basefee <= tx.gasprice &&
        //         tx.gasprice <=
        //         uint256(IAggregator(_FAST_GAS_ORACLE).latestAnswer()),
        //     "GasThrottle::validateGas: Gas Exceeds Thresholds"
        // );
        _;
    }
}

contract SwapQueue is ISwapQueue, ProtocolConstants {
    using Address for address payable;

    mapping(uint256 => Queue) public queue;

    /* ========== STATE VARIABLES ========== */
    /* ========== CONSTRUCTOR ========== */
    /* ========== VIEWS ========== */
    /* ========== MUTATIVE FUNCTIONS ========== */

    function executeQueue() external {
        uint256 reimbursement = _executeQueue();
        payable(msg.sender).sendValue(reimbursement);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    /* ========== INTERNAL FUNCTIONS ========== */

    function _insertQueue(uint256 value) internal returns (bool) {}

    function _executeQueue() internal returns (uint256) {}
    /* ========== PRIVATE FUNCTIONS ========== */
    /* ========== MODIFIERS ========== */
}

abstract contract RewardsDistributionRecipient is Owned {
    address public rewardsDistribution;

    function notifyRewardAmount(uint reward) external virtual;

    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "not reward distribution");
        _;
    }

    function setRewardsDistribution(address _rewardsDistribution) external onlyOwner {
        rewardsDistribution = _rewardsDistribution;
    }
}

abstract contract Pausable is Owned {
    uint public lastPauseTime;
    bool public paused;

    constructor() {
        // This contract is abstract, and thus cannot be instantiated directly
        require(owner != address(0), "Owner must be set");
        // Paused will be false, and lastPauseTime will be 0 upon initialisation
    }

    /**
     * @notice Change the paused state of the contract
     * @dev Only the contract owner may call this.
     */
    function setPaused(bool _paused) external onlyOwner {
        // Ensure we're actually changing the state before we do anything
        if (_paused == paused) {
            return;
        }

        // Set our paused state.
        paused = _paused;

        // If applicable, set the last pause time.
        if (_paused) {
            lastPauseTime = block.timestamp;
        }

        // Let everyone know that our pause state has changed.
        emit PauseChanged(_paused);
    }

    event PauseChanged(bool isPaused);

    modifier notPaused() {
        require(!paused, "paused");
        _;
    }
}

contract UniswapV2ERC20 is IUniswapV2ERC20 {
    string public constant name = "Uniswap V2";
    string public constant symbol = "UNI-V2";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint256) public nonces;

    constructor() {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint256 value) internal {
        totalSupply = totalSupply + value;
        balanceOf[to] = balanceOf[to] + value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        balanceOf[from] = balanceOf[from] - value;
        totalSupply = totalSupply - value;
        emit Transfer(from, address(0), value);
    }

    function _approve(
        address owner,
        address spender,
        uint256 value
    ) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(
        address from,
        address to,
        uint256 value
    ) private {
        balanceOf[from] = balanceOf[from] - value;
        balanceOf[to] = balanceOf[to] + value;
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] = allowance[from][msg.sender] - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "UniswapV2: EXPIRED");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonces[owner]++,
                        deadline
                    )
                )
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(
            recoveredAddress != address(0) && recoveredAddress == owner,
            "UniswapV2: INVALID_SIGNATURE"
        );
        _approve(owner, spender, value);
    }
}

interface IUniswapV2Pair is IUniswapV2ERC20 {
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to)
        external
        returns (uint256 amount0, uint256 amount1);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;
}

/**
 * @dev Implementation of {Timelock} contract.
 *
 * It allows queueing, execution and cancellation of transactions by the
 * {admin}. A queued transaction can be executed after the cool-time represented
 * by {delay} has elapsed and grace period has not passed since the queuing
 * of transaction.
 *
 * It allows changing of contract's admin through a queued transaction by the
 * prior admin. The new admin the calls {acceptAdmin} to accept its role.
 */
contract Timelock is ITimelock {
    // Current admin of the contract
    address public admin;

    // Pending admin of the contract
    address public pendingAdmin;

    // Cool-off before a queued transaction is executed
    uint256 public override delay;

    // Queued status of a transaction (txHash => tx status).
    mapping(bytes32 => bool) public override queuedTransactions;

    // Emitted when a new admin is set
    event NewAdmin(address indexed newAdmin);

    // Emitted when a new pending admin is set
    event NewPendingAdmin(address indexed newPendingAdmin);

    // Emitted when a new delay/cool-off time is set
    event NewDelay(uint256 indexed newDelay);

    // Emitted when a tx is cancelled
    event CancelTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    // Emitted when a tx is executed
    event ExecuteTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    // Emitted when a tx is queued
    event QueueTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    /**
     * @dev Allows of receiving of ether beforehand or in bulk, so the sending
     * ether is optional at the time of tx execution.
     */
    receive() external payable {}

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Sets contract's state variable of {admin} and {delay}
     *
     * Requirements:
     * - `admin_` param must not be a zero address
     * - `delay_` param must be within range or min and max delay
     */
    constructor(address admin_, uint256 delay_) {
        require(
            delay_ >= MINIMUM_DELAY(),
            "Timelock::constructor: Delay must exceed minimum delay."
        );
        require(
            delay_ <= MAXIMUM_DELAY(),
            "Timelock::constructor: Delay must not exceed maximum delay."
        );

        require(
            admin_ != address(0),
            "Timelock::constructor: Admin cannot be zero"
        );

        admin = admin_;
        delay = delay_;
    }

    /* ========== VIEWS ========== */
    /**
     * @dev Returns the time period a tx is valid for execution after eta has elapsed.
     */
    function GRACE_PERIOD() public pure virtual override returns (uint256) {
        return 14 days;
    }

    /**
     * @dev Returns the minimum delay required for execution after a tx is queued
     */
    function MINIMUM_DELAY() public pure virtual returns (uint256) {
        return 2 days;
    }

    /**
     * @dev Returns the maxium delay required for execution after a tx is queued
     */
    function MAXIMUM_DELAY() public pure virtual returns (uint256) {
        return 30 days;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
     * @dev Sets the the new value of {delay}.
     * It allows setting of new delay value through queued tx by the admin
     *
     * Requirements:
     * - only current contract can call it
     * - `delay_` param must be within the min and max delay range
     */
    function setDelay(uint256 delay_) public {
        require(
            msg.sender == address(this),
            "Timelock::setDelay: Call must come from Timelock."
        );
        require(
            delay_ >= MINIMUM_DELAY(),
            "Timelock::setDelay: Delay must exceed minimum delay."
        );
        require(
            delay_ <= MAXIMUM_DELAY(),
            "Timelock::setDelay: Delay must not exceed maximum delay."
        );
        delay = delay_;

        emit NewDelay(delay);
    }

    /**
     * @dev Sets {pendingAdmin} to admin of current contract.
     * A {GovernorAlpha} contract which is already set as {pendingAdmin}
     * of this contract calls this function to set itself as new admin.
     *
     * Requirements:
     * - only callable by {pendingAdmin}
     */
    function acceptAdmin() public override {
        require(
            msg.sender == pendingAdmin,
            "Timelock::acceptAdmin: Call must come from pendingAdmin."
        );
        admin = msg.sender;
        pendingAdmin = address(0);

        emit NewAdmin(admin);
    }

    /**
     * @dev Sets the the new value of {pendingAdmin_}.
     * It allows setting of new pendingAdmin value through queued tx by the admin
     *
     * Requirements:
     * - only current contract can call it
     */
    function setPendingAdmin(address pendingAdmin_) public {
        require(
            msg.sender == address(this),
            "Timelock::setPendingAdmin: Call must come from Timelock."
        );
        pendingAdmin = pendingAdmin_;

        emit NewPendingAdmin(pendingAdmin);
    }

    /**
     * @dev Queues a transaction by setting its status in {queuedTransactions} mapping.
     *
     * Requirements:
     * - only callable by {admin}
     * - `eta` must lie in future compared to delay referenced from current block
     */
    function queueTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) public override returns (bytes32 txHash) {
        require(
            msg.sender == admin,
            "Timelock::queueTransaction: Call must come from admin."
        );
        require(
            eta >= getBlockTimestamp() + delay,
            "Timelock::queueTransaction: Estimated execution block must satisfy delay."
        );

        txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data, eta);
    }

    /**
     * @dev Cancels a transaction by setting its status in {queuedTransactions} mapping.
     *
     * Requirements:
     * - only callable by {admin}
     */
    function cancelTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) public override {
        require(
            msg.sender == admin,
            "Timelock::cancelTransaction: Call must come from admin."
        );

        bytes32 txHash = keccak256(
            abi.encode(target, value, signature, data, eta)
        );
        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    /**
     * @dev Executes a transaction by making a low level call to its `target`.
     * The call reverts if the low-level call made to `target` reverts.
     *
     * Requirements:
     * - only callable by {admin}
     * - tx must already be queued
     * - current timestamp is ahead of tx's eta
     * - grace period associated with the tx must not have passed
     * - the low-level call to tx's `target` must not revert
     */
    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) public payable override returns (bytes memory) {
        require(
            msg.sender == admin,
            "Timelock::executeTransaction: Call must come from admin."
        );

        bytes32 txHash = keccak256(
            abi.encode(target, value, signature, data, eta)
        );
        require(
            queuedTransactions[txHash],
            "Timelock::executeTransaction: Transaction hasn't been queued."
        );
        require(
            getBlockTimestamp() >= eta,
            "Timelock::executeTransaction: Transaction hasn't surpassed time lock."
        );
        require(
            getBlockTimestamp() <= eta + GRACE_PERIOD(),
            "Timelock::executeTransaction: Transaction is stale."
        );

        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(
                bytes4(keccak256(bytes(signature))),
                data
            );
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value: value}(
            callData
        );

        require(
            success,
            "Timelock::executeTransaction: Transaction execution reverted."
        );

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);

        return returnData;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @dev Gets timestamp from the current block.
     */
    function getBlockTimestamp() internal view returns (uint256) {
        // solium-disable-next-line security/no-block-members
        return block.timestamp;
    }
}
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
interface IERC721 is IERC165 {
    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be have been allowed to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *
     * WARNING: Usage of this method is discouraged, use {safeTransferFrom} whenever possible.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint256 tokenId) external view returns (address operator);

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the caller.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool _approved) external;

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;
}

interface IVaderPool is IBasePool, IERC721 {
    /* ========== STRUCTS ========== */
    /* ========== FUNCTIONS ========== */

    function burn(uint256 id, address to)
        external
        returns (
            uint256 amountNative,
            uint256 amountForeign,
            uint256 coveredLoss
        );

    function toggleQueue() external;

    /* ========== EVENTS ========== */

    event QueueActive(bool activated);
}

contract USDV is IUSDV, ProtocolConstants, ERC20, Ownable {
    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable vader;
    IVaderReserve public immutable reserve;

    /* ========== CONSTRUCTOR ========== */

    constructor(IERC20 _vader, IVaderReserve _reserve)
        ERC20("Vader USD", "USDV")
    {
        require(
            _reserve != IVaderReserve(_ZERO_ADDRESS),
            "USDV::constructor: Incorrect Arguments"
        );
        vader = _vader;
        reserve = _reserve;
    }

    /* ========== VIEWS ========== */

    /* ========== MUTATIVE FUNCTIONS ========== */

    function distributeEmission() external override {
        // TODO: Adjust when incentives clearly defined
        uint256 balance = vader.balanceOf(address(this));
        vader.transfer(address(reserve), balance);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== PRIVATE FUNCTIONS ========== */

    /* ========== MODIFIERS ========== */
}

/**
 * @dev Implementation of the {IVader} interface.
 *
 * The Vader token that acts as the backbone of the Vader protocol,
 * burned and minted to mint and burn USDV tokens respectively.
 *
 * The token contains a dynamically adjusting fee that fluctuates
 * between 0% and 1% depending on the total supply of the token
 * in comparison to the maximum supply possible, which is initially
 * equal to 2.5 billion units.
 *
 * A daily emission schedule is built in the contract as well,
 * meant to supply the Vader USDV treasury at a diminishing
 * rate that inches closer to 0 as the total supply of the token
 * nears the maximum supply possible.
 */
contract Vader is IVader, ProtocolConstants, ERC20, Ownable {
    /* ========== STATE VARIABLES ========== */

    // The Vader <-> Vether converter contract
    IConverter public converter;

    // The Vader Team vesting contract
    ILinearVesting public vest;

    // The USDV contract, used to apply proper access control
    IUSDV public usdv;

    // The adjustable emission curve of the protocol, used as a divisor
    uint256 public emissionCurve = _INITIAL_EMISSION_CURVE;

    // The last emission's timestamp expressed in seconds
    uint256 public lastEmission = block.timestamp;

    // The initial maximum supply of the token, equivalent to 2.5 bn units
    uint256 public maxSupply = _INITIAL_VADER_SUPPLY;

    // A list of addresses that do not have a tax applied to them, used for system components
    mapping(address => bool) public untaxed;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Mints the ecosystem growth fund described in the whitepaper to the
     * token contract itself.
     *
     * As the token is meant to be minted and burned freely between USDV and itself,
     * there is no real initialization taking place apart from the initially minted
     * supply for the following components:
     *
     * - Ecosystem Growth: An allocation that is released to strategic partners for the
     * protocol's expansion
     *
     * - Team Allocation: An allocation that is gradually vested over a 2 year duration to
     * the Vader team to incentivize maintainance of the protocol
     *
     * - Vether Holder Allocation: An allocation that is immediately available to all existing
     * and future Vether holders that allows them to swap their Vether for Vader by burning the
     * former
     *
     * The latter two of the allocations are minted at a later date given that the addresses of
     * the converter and vesting contract are not known on deployment.
     */
    constructor() ERC20("Vader", "VADER") {
        _mint(address(this), _ECOSYSTEM_GROWTH);
    }

    /* ========== VIEWS ========== */

    /**
     * @dev Returns the current fee that the protocol applies to transactions. The fee
     * organically adjusts itself as the actual total supply of the token fluctuates and
     * will always hold a value between [0%, 1%] expressed in basis points.
     */
    function calculateFee() public view override returns (uint256 basisPoints) {
        basisPoints = (_MAX_FEE_BASIS_POINTS * totalSupply()) / maxSupply;
    }

    /**
     * @dev Returns the current era's emission based on the existing total supply of the
     * token. The era emissions diminish as the total supply of the token increases, inching
     * closer to 0 as the total supply reaches its cap.
     */
    function getCurrentEraEmission() external view override returns (uint256) {
        return getEraEmission(totalSupply());
    }

    /**
     * @dev Calculates and returns the constantly diminishing era emission based on the difference between
     * the current and maximum supply spread over a one year based in on the emission's era duration.
     */
    function getEraEmission(uint256 currentSupply)
        public
        view
        override
        returns (uint256)
    {
        return
            ((maxSupply - currentSupply) / emissionCurve) /
            (_ONE_YEAR / _EMISSION_ERA);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @dev Creates a manual emission event
     *
     * Emits an {Emission} event indicating the amount emitted as well as what the current
     * era's timestamp is.
     */
    function createEmission(address user, uint256 amount)
        external
        override
        onlyOwner
    {
        _mint(user, amount);
        emit Emission(user, amount);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
     * @dev Sets the initial {converter}, {vest}, and {usdv} contract addresses prior to transferring
     * ownership to the DAO. Additionally, mints the Vader amount available for conversion as well
     * as the team allocation that is meant to be vested to each respective contract.
     *
     * Emits a {ProtocolInitialized} event indicating all the supplied values of the function.
     *
     * Requirements:
     *
     * - the caller must be the deployer of the contract
     * - the contract must not have already been initialized
     */
    function setComponents(
        IConverter _converter,
        ILinearVesting _vest,
        IUSDV _usdv,
        address dao
    ) external onlyOwner {
        require(
            _converter != IConverter(_ZERO_ADDRESS) &&
                _vest != ILinearVesting(_ZERO_ADDRESS) &&
                _usdv != IUSDV(_ZERO_ADDRESS) &&
                dao != _ZERO_ADDRESS,
            "Vader::setComponents: Incorrect Arguments"
        );
        require(
            converter == IConverter(_ZERO_ADDRESS),
            "Vader::setComponents: Already Set"
        );

        converter = _converter;
        vest = _vest;
        usdv = _usdv;

        untaxed[address(_converter)] = true;
        untaxed[address(_vest)] = true;
        untaxed[address(_usdv)] = true;

        _mint(address(_converter), _VETH_ALLOCATION);
        _mint(address(_vest), _TEAM_ALLOCATION);

        _vest.begin();
        // transferOwnership(dao);

        emit ProtocolInitialized(
            address(_converter),
            address(_vest),
            address(_usdv),
            dao
        );
    }

    /**
     * @dev Allows a strategic partnership grant to be claimed.
     *
     * Emits a {GrantClaimed} event indicating the beneficiary of the grant as
     * well as the grant amount.
     *
     * Requirements:
     *
     * - the caller must be the DAO
     * - the token must hold sufficient Vader allocation for the grant
     * - the grant must be of a non-zero amount
     */
    function claimGrant(address beneficiary, uint256 amount) external onlyDAO {
        require(amount != 0, "Vader::claimGrant: Non-Zero Amount Required");
        emit GrantClaimed(beneficiary, amount);
        ERC20._transfer(address(this), beneficiary, amount);
    }

    /**
     * @dev Allows the maximum supply of the token to be adjusted.
     *
     * Emits an {MaxSupplyChanged} event indicating the previous and next maximum
     * total supplies.
     *
     * Requirements:
     *
     * - the caller must be the DAO
     * - the new maximum supply must be greater than the current one
     */
    function adjustMaxSupply(uint256 _maxSupply) external onlyDAO {
        require(
            _maxSupply >= totalSupply(),
            "Vader::adjustMaxSupply: Max supply cannot subcede current supply"
        );
        emit MaxSupplyChanged(maxSupply, _maxSupply);
        maxSupply = _maxSupply;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @dev Ensures that the daily emission of the token gets automatically executed
     * when the time is right and enforces the maximum supply limit on mint operations.
     */
    function _beforeTokenTransfer(
        address from,
        address,
        uint256 amount
    ) internal view override {
        if (from == address(0))
            require(
                totalSupply() + amount <= maxSupply,
                "Vader::_beforeTokenTransfer: Mint exceeds cap"
            );

        // _syncEmissions();
    }

    /**
     * @dev Overrides the existing ERC-20 {_transfer} functionality to apply a fee on each
     * transfer.
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        if (untaxed[msg.sender])
            return ERC20._transfer(sender, recipient, amount);

        uint256 fee = calculateFee();

        uint256 tax = (amount * fee) / _MAX_BASIS_POINTS;

        amount -= tax;

        _burn(sender, tax);

        ERC20._transfer(sender, recipient, amount);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /**
     * @dev Ensures only the DAO is able to invoke a particular function by validating that the
     * contract has been set up and that the owner is the msg.sender
     */
    function _onlyDAO() private view {
        require(
            converter != IConverter(_ZERO_ADDRESS),
            "Vader::_onlyDAO: DAO not set yet"
        );
        require(
            owner == _msgSender(),
            "Vader::_onlyDAO: Insufficient Privileges"
        );
    }

    /* ========== MODIFIERS ========== */

    /**
     * @dev Throws if invoked by anyone else other than the DAO
     */
    modifier onlyDAO() {
        _onlyDAO();
        _;
    }

    /* ========== DEPRECATED FUNCTIONS ========== */

    /**
     * @dev Allows the daily emission curve of the token to be adjusted.
     *
     * Emits an {EmissionChanged} event indicating the previous and next emission
     * curves.
     *
     * Requirements:
     *
     * - the caller must be the DAO
     * - the new emission must be non-zero
     */
    // function adjustEmission(uint256 _emissionCurve) external onlyDAO {
    //     require(
    //         _emissionCurve != 0,
    //         "Vader::adjustEmission: Incorrect Curve Emission"
    //     );
    //     emit EmissionChanged(emissionCurve, _emissionCurve);
    //     emissionCurve = _emissionCurve;
    // }

    /**
     * @dev Syncs the current emission schedule by advancing the necessary epochs to match the
     * current timestamp and mints the corresponding Vader to the USDV contract for distribution
     * via the {distributeEmission} function.
     */
    // function _syncEmissions() private {
    //     uint256 currentSupply = totalSupply();
    //     uint256 _lastEmission = lastEmission;
    //     if (
    //         block.timestamp >= _lastEmission + _EMISSION_ERA &&
    //         maxSupply != currentSupply
    //     ) {
    //         uint256 eras = (block.timestamp - _lastEmission) / _EMISSION_ERA;

    //         // NOTE: Current Supply + Emission guaranteed to not overflow as <= maxSupply
    //         uint256 emission;
    //         for (uint256 i = 0; i < eras; i++)
    //             emission += getEraEmission(currentSupply + emission);

    //         _mint(address(usdv), emission);

    //         usdv.distributeEmission();

    //         _lastEmission += (_EMISSION_ERA * eras);
    //         lastEmission = _lastEmission;

    //         emit Emission(emission, _lastEmission);
    //     }
    // }
}

/**
 * @dev Implementation of the {ILinearVesting} interface.
 *
 * The straightforward vesting contract that gradually releases a
 * fixed supply of tokens to multiple vest parties over a 2 year
 * window.
 *
 * The token expects the {begin} hook to be invoked the moment
 * it is supplied with the necessary amount of tokens to vest,
 * which should be equivalent to the time the {setComponents}
 * function is invoked on the Vader token.
 */
contract LinearVesting is ILinearVesting, ProtocolConstants, Ownable {
    /* ========== LIBRARIES ========== */

    // Used for safe VADER transfers
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // The Vader token
    IERC20 public immutable vader;

    // The start of the vesting period
    uint256 public start;

    // The end of the vesting period
    uint256 public end;

    // The status of each vesting member (Vester)
    mapping(address => Vester) public vest;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Initializes the contract's vesters and vesting amounts as well as sets
     * the Vader token address.
     *
     * It conducts a sanity check to ensure that the total vesting amounts specified match
     * the team allocation to ensure that the contract is deployed correctly.
     *
     * Additionally, it transfers ownership to the Vader contract that needs to consequently
     * initiate the vesting period via {begin} after it mints the necessary amount to the contract.
     */
    constructor(
        IERC20 _vader,
        address[] memory vesters,
        uint192[] memory amounts
    ) {
        require(
            _vader != IERC20(_ZERO_ADDRESS) && vesters.length == amounts.length,
            "LinearVesting::constructor: Misconfiguration"
        );

        vader = _vader;

        uint256 total;
        for (uint256 i = 0; i < vesters.length; i++) {
            require(
                amounts[i] != 0,
                "LinearVesting::constructor: Incorrect Amount Specified"
            );
            vest[vesters[i]].amount = amounts[i];
            total = total + amounts[i];
        }
        require(
            total == _TEAM_ALLOCATION,
            "LinearVesting::constructor: Invalid Vest Amounts Specified"
        );

        // transferOwnership(address(_vader));
    }

    /* ========== VIEWS ========== */

    /**
     * @dev Returns the amount a user can claim at a given point in time.
     *
     * Requirements:
     * - the vesting period has started
     */
    function getClaim()
        external
        view
        override
        hasStarted
        returns (uint256 vestedAmount)
    {
        Vester memory vester = vest[msg.sender];
        return _getClaim(vester.amount, vester.lastClaim);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @dev Allows a user to claim their pending vesting amount.
     *
     * Emits a {Vested} event indicating the user who claimed their vested tokens
     * as well as the amount that was vested.
     *
     * Requirements:
     *
     * - the vesting period has started
     * - the caller must have a non-zero vested amount
     */
    function claim()
        external
        override
        hasStarted
        returns (uint256 vestedAmount)
    {
        Vester memory vester = vest[msg.sender];

        require(
            vester.start == 0,
            "LinearVesting::claim: Incorrect Vesting Type"
        );

        vestedAmount = _getClaim(vester.amount, vester.lastClaim);

        require(vestedAmount != 0, "LinearVesting::claim: Nothing to claim");

        vester.amount -= uint192(vestedAmount);
        vester.lastClaim = uint64(block.timestamp);

        vest[msg.sender] = vester;

        emit Vested(msg.sender, vestedAmount);

        vader.safeTransfer(msg.sender, vestedAmount);
    }

    /**
     * @dev Allows a user to claim their pending vesting amount of the vested claim
     *
     * Emits a {Vested} event indicating the user who claimed their vested tokens
     * as well as the amount that was vested.
     *
     * Requirements:
     *
     * - the vesting period has started
     * - the caller must have a non-zero vested amount
     */
    function claimConverted() external override returns (uint256 vestedAmount) {
        Vester memory vester = vest[msg.sender];

        require(
            vester.start != 0,
            "LinearVesting::claim: Incorrect Vesting Type"
        );

        require(
            vester.start < block.timestamp,
            "LinearVesting::claim: Not Started Yet"
        );

        vestedAmount = _getClaim(
            vester.amount,
            vester.lastClaim,
            vester.start,
            vester.end
        );

        require(vestedAmount != 0, "LinearVesting::claim: Nothing to claim");

        vester.amount -= uint192(vestedAmount);
        vester.lastClaim = uint64(block.timestamp);

        vest[msg.sender] = vester;

        emit Vested(msg.sender, vestedAmount);

        vader.safeTransfer(msg.sender, vestedAmount);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
     * @dev Allows the vesting period to be initiated.
     *
     * Emits a {VestingInitialized} event from which the start and
     * end can be calculated via it's attached timestamp.
     *
     * Requirements:
     *
     * - the caller must be the owner (vader token)
     */
    function begin() external override onlyOwner {
        start = block.timestamp;
        end = block.timestamp + _VESTING_DURATION;

        emit VestingInitialized(_VESTING_DURATION);

        // renounceOwnership();
    }

    /**
     * @dev Adds a new vesting schedule to the contract
     */
    function vestFor(address user, uint256 amount) external override {
        require(
            vest[user].amount == 0,
            "LinearVesting::selfVest: Already a vester"
        );
        vest[user] = Vester(
            uint192(amount),
            0,
            uint128(block.timestamp),
            uint128(block.timestamp + 365 days)
        );
        vader.safeTransferFrom(msg.sender, address(this), amount);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /**
     * @dev Calculates the amount a user's vest is due. To calculate,
     * the following formula is utilized:
     *
     * - (remainingAmount * timeElapsed) / timeUntilEnd
     *
     * Each variable is described as follows:
     *
     * - remainingAmount (amount): Vesting amount remaining. Each claim subtracts from
     * this amount to ensure calculations are properly conducted.
     *
     * - timeElapsed (block.timestamp.sub(lastClaim)): Time that has elapsed since the
     * last claim.
     *
     * - timeUntilEnd (end.sub(lastClaim)): Time remaining for the particular vesting
     * member's total duration.
     *
     * Vesting calculations are relative and always update the last
     * claim timestamp as well as remaining amount whenever they
     * are claimed.
     */
    function _getClaim(uint256 amount, uint256 lastClaim)
        private
        view
        returns (uint256)
    {
        uint256 _end = end;

        if (block.timestamp >= _end) return amount;
        if (lastClaim == 0) lastClaim = start;

        return (amount * (block.timestamp - lastClaim)) / (_end - lastClaim);
    }

    /**
     * @dev Calculates the amount a user's vest is due. To calculate,
     * the following formula is utilized:
     *
     * - (remainingAmount * timeElapsed) / timeUntilEnd
     *
     * Each variable is described as follows:
     *
     * - remainingAmount (amount): Vesting amount remaining. Each claim subtracts from
     * this amount to ensure calculations are properly conducted.
     *
     * - timeElapsed (block.timestamp.sub(lastClaim)): Time that has elapsed since the
     * last claim.
     *
     * - timeUntilEnd (end.sub(lastClaim)): Time remaining for the particular vesting
     * member's total duration.
     *
     * Vesting calculations are relative and always update the last
     * claim timestamp as well as remaining amount whenever they
     * are claimed.
     */
    function _getClaim(
        uint256 amount,
        uint256 lastClaim,
        uint256 _start,
        uint256 _end
    ) private view returns (uint256) {
        if (block.timestamp >= _end) return amount;
        if (lastClaim == 0) lastClaim = _start;

        return (amount * (block.timestamp - lastClaim)) / (_end - lastClaim);
    }

    /**
     * @dev Validates that the vesting period has started
     */
    function _hasStarted() private view {
        require(
            start != 0,
            "LinearVesting::_hasStarted: Vesting hasn't started yet"
        );
    }

    /* ========== MODIFIERS ========== */

    /**
     * @dev Throws if the vesting period hasn't started
     */
    modifier hasStarted() {
        _hasStarted();
        _;
    }
}

/**
 * @dev Implementation of the {IConverter} interface.
 *
 * A simple converter contract that allows users to convert
 * their Vether tokens by "burning" them (See {convert}) to
 * acquire their equivalent Vader tokens based on the constant
 * {VADER_VETHER_CONVERSION_RATE}.
 *
 * The contract assumes that it has been sufficiently funded with
 * Vader tokens and will fail to execute trades if it has not been
 * done so yet.
 */
library MerkleProof {
    /**
     * @dev Returns true if a `leaf` can be proved to be a part of a Merkle tree
     * defined by `root`. For this, a `proof` must be provided, containing
     * sibling hashes on the branch from the leaf to the root of the tree. Each
     * pair of leaves and each pair of pre-images are assumed to be sorted.
     */
    function verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];

            if (computedHash <= proofElement) {
                // Hash(current computed hash + current element of the proof)
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                // Hash(current element of the proof + current computed hash)
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }

        // Check if the computed hash (root) is equal to the provided root
        return computedHash == root;
    }
}
contract Converter is IConverter, ProtocolConstants {
    /* ========== LIBRARIES ========== */

    // Used for safe VADER & VETHER transfers
    using SafeERC20 for IERC20;

    // Using MerkleProof for validating claims
    using MerkleProof for bytes32[];

    /* ========== STATE VARIABLES ========== */

    // The VETHER token
    IERC20 public immutable vether;

    // The VADER token
    IERC20 public immutable vader;

    // The VADER vesting contract
    ILinearVesting public immutable vesting;

    // The merkle proof root for validating claims
    bytes32 public immutable root;

    // Signals whether a particular leaf has been claimed of the merkle proof
    mapping(bytes32 => bool) public claimed;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Initializes the contract's {vether} and {vader} addresses.
     *
     * Performs rudimentary checks to ensure that the variables haven't
     * been declared incorrectly.
     */
    constructor(
        IERC20 _vether,
        IERC20 _vader,
        ILinearVesting _vesting,
        bytes32 _root
    ) {
        require(
            _vether != IERC20(_ZERO_ADDRESS) &&
                _vader != IERC20(_ZERO_ADDRESS) &&
                _vesting != ILinearVesting(_ZERO_ADDRESS),
            "Converter::constructor: Misconfiguration"
        );

        vether = _vether;
        vader = _vader;

        _vader.approve(address(_vesting), type(uint256).max);

        vesting = _vesting;
        root = _root;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @dev Allows a user to convert their Vether to Vader.
     *
     * Emits a {Conversion} event indicating the amount of Vether the user
     * "burned" and the amount of Vader that they acquired.
     *
     * Here, "burned" refers to the action of transferring them to an irrecoverable
     * address, the {BURN} address.
     *
     * Requirements:
     *
     * - the caller has approved the contract for the necessary amount via Vether
     * - the amount specified is non-zero
     * - the contract has been supplied with the necessary Vader amount to fulfill the trade
     */
    function convert(bytes32[] calldata proof, uint256 amount)
        external
        override
        returns (uint256 vaderReceived)
    {
        require(
            amount != 0,
            "Converter::convert: Non-Zero Conversion Amount Required"
        );

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(
            !claimed[leaf] && proof.verify(root, leaf),
            "Converter::convert: Incorrect Proof Provided"
        );
        claimed[leaf] = true;

        vaderReceived = amount * _VADER_VETHER_CONVERSION_RATE;

        emit Conversion(msg.sender, amount, vaderReceived);

        vether.safeTransferFrom(msg.sender, _BURN, amount);
        uint256 half = vaderReceived / 2;
        vader.safeTransfer(msg.sender, half);
        vesting.vestFor(msg.sender, half);
    }
}

pragma experimental ABIEncoderV2;


/**
 * @dev Implementation of {GovernorAlpha} contract.
 *
 * The GovernorAlpha contract allows creation of proposals by anyone
 * by depositing xVader (1000 xVader initially).
 *
 * Anyone can vote on the created proposals utilizing their xVader weight in
 * xVader contract.
 *
 * Only 1 proposal can be active at a time by a particular proposer.
 *
 * A proposal is queued when it succeeds and can be executed after a cool-off
 * time period specified by {delay} in the Timelock contract.
 *
 * A proposal can be cancelled by a {guardian} if it has not been already
 * executed.
 *
 * A proposal can be vetoed by {council} while its state is active/pending
 * and a proposal vetoed with success is also queued at the same time.
 */
contract GovernorAlpha {
    // The name of this contract
    string public constant name = "Vader Governor Alpha";

    // The address of the Vader Protocol Timelock
    ITimelock public timelock;

    // The address of the Governor Guardian
    address public guardian;

    // The total number of proposals
    uint256 public proposalCount;

    // address of xVader token
    IXVader public immutable xVader;

    // address of fee receiver
    address public feeReceiver;

    // amount of fee deducted when proposing proposal
    uint256 public feeAmount;

    // address of council that is allowed to veto on proposals
    address public council;

    /**
     * @dev {Proposal} struct contains parameters for a single proposal.
     * id: Unique id for looking up a proposal.
     * canceled: Flag marking whether the proposal has been canceled.
     * executed: Flag marking whether the proposal has been executed.
     * proposer: Creator of the proposal
     * eta: The timestamp that the proposal will be available for execution, set once the vote succeeds
     * targets: the ordered list of target addresses for calls to be made
     * values: The ordered list of values (i.e. msg.value) to be passed to the calls to be made
     * signatures: The ordered list of function signatures to be called
     * calldatas: The ordered list of calldata to be passed to each call
     * startBlock: startBlock: The block at which voting begins: holders must delegate their votes prior to this block
     * endBlock: The block at which voting ends: votes must be cast prior to this block
     * forVotes: Current number of votes in favor of this proposal
     * againstVotes: Current number of votes in opposition to this proposal
     * receipts: Receipts of ballots for the entire set of voters
     * vetoStatus: Veto status if the proposal has been vetoed by council in favor or against
     */
    struct Proposal {
        uint256 id;
        bool canceled;
        bool executed;
        address proposer;
        uint256 eta;
        address[] targets;
        uint256[] values;
        string[] signatures;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        uint224 forVotes;
        uint224 againstVotes;
        VetoStatus vetoStatus;
        mapping(address => Receipt) receipts;
    }

    /**
     * @dev {Receipt} struct contains parameters for a voter against a particular proposal
     * and is a ballot receipt record for a voter.
     *
     * hasVoted: Whether or not a vote has been casted
     * support: Whether or not the voter supports the proposal
     * votes: The number of votes the voter had, which were cast
     */
    struct Receipt {
        bool hasVoted;
        bool support;
        uint224 votes;
    }

    /**
     * @dev {VetoStatus} contains parameters representing if a proposal has been vetoed by council
     *
     * hasBeenVetoed: Whether proposal has been vetoed or not
     * support: Whether veto is in favor or against of proposal
     */
    struct VetoStatus {
        bool hasBeenVetoed;
        bool support;
    }

    // Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    // The official record of all proposals ever proposed
    mapping(uint256 => Proposal) public proposals;

    // The latest proposal for each proposer
    mapping(address => uint256) public latestProposalIds;

    // The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
        );

    // The EIP-712 typehash for the ballot struct used by the contract
    bytes32 public constant BALLOT_TYPEHASH =
        keccak256("Ballot(uint256 proposalId,bool support)");

    // An event emitted when a new proposal is created
    event ProposalCreated(
        uint256 id,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );

    // An event emitted when a vote has been cast on a proposal
    event VoteCast(
        address voter,
        uint256 proposalId,
        bool support,
        uint256 votes
    );

    // An event emitted when a proposal has been canceled
    event ProposalCanceled(uint256 id);

    // An event emitted when a proposal has been queued in the Timelock
    event ProposalQueued(uint256 id, uint256 eta);

    // An event emitted when a proposal has been executed in the Timelock
    event ProposalExecuted(uint256 id);

    // An event emitted when fee receiver is changed
    event FeeReceiverChanged(address oldFeeReceiver, address newFeeReceiver);

    // An event emitted when fee amount is changed
    event FeeAmountChanged(uint256 oldFeeAmount, uint256 newFeeAmount);

    // An event emitted when a proposal has been vetoed by the council
    event ProposalVetoed(uint256 proposalId, bool support);

    // An event emitted when council is changed
    event CouncilChanged(address oldCouncil, address newCouncil);

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Initializes the contract's state setting xVader, fee receiver,
     * council and guardian addresses along with the fee amount.
     *
     * It performs sanity checks for the address type parameters against zero
     * address values.
     */
    constructor(
        address guardian_,
        address xVader_,
        address feeReceiver_,
        uint256 feeAmount_,
        address council_
    ) {
        require(
            xVader_ != address(0),
            "GovernorAlpha::constructor: xVader address is zero"
        );

        require(
            guardian_ != address(0) &&
                feeReceiver_ != address(0) &&
                council_ != address(0),
            "GovernorAlpha::constructor: guardian, feeReceiver or council cannot be zero"
        );

        guardian = guardian_;
        xVader = IXVader(xVader_);
        feeReceiver = feeReceiver_;
        feeAmount = feeAmount_;
        council = council_;

        emit FeeReceiverChanged(address(0), feeReceiver_);
        emit FeeAmountChanged(0, feeAmount_);
    }

    /* ========== VIEWS ========== */

    // The number of votes in support of a proposal required in order for a quorum to be reached and for a vote to succeed
    function quorumVotes(uint256 blockNumber) public view returns (uint256) {
        return (xVader.getPastTotalSupply(blockNumber) * 4) / 100; // 4% of xVader's supply at the time of proposal creation.
    }

    // The maximum number of actions that can be included in a proposal
    function proposalMaxOperations() public pure returns (uint256) {
        return 10; // 10 actions
    }

    // The delay before voting on a proposal may take place, once proposed
    function votingDelay() public pure returns (uint256) {
        return 1; // 1 block
    }

    // The duration of voting on a proposal, in blocks
    function votingPeriod() public pure virtual returns (uint256) {
        return 17280; // ~3 days in blocks (assuming 15s blocks)
    }

    /**
     * @dev Returns the actions contained in a proposal with id {proposalId}.
     */
    function getActions(uint256 proposalId)
        public
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    /**
     * @dev Returns receipt of the {voter} against the proposal with id {proposalId}.
     */
    function getReceipt(uint256 proposalId, address voter)
        public
        view
        returns (Receipt memory)
    {
        return proposals[proposalId].receipts[voter];
    }

    /**
     * @dev Returns the current state of the proposal with id {proposalId}.
     *
     * Requirements:
     * - The {proposalId} should be greater than 0
     * - The {proposalId} should be less than or equal to {proposalCount}
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        require(
            proposalCount >= proposalId && proposalId > 0,
            "GovernorAlpha::state: invalid proposal id"
        );

        Proposal storage proposal = proposals[proposalId];
        if (proposal.canceled) return ProposalState.Canceled;

        if (proposal.vetoStatus.hasBeenVetoed) {
            // proposal has been vetoed
            uint256 _eta = proposal.eta;

            // proposal has been vetoed in favor, so considered succeeded
            if (proposal.vetoStatus.support && _eta == 0)
                return ProposalState.Succeeded;

            // proposal has been vetoed against, so considered defeated
            if (_eta == 0) return ProposalState.Defeated;
        } else {
            // proposal has not been vetoed, normal flow ensues
            if (block.number <= proposal.startBlock)
                return ProposalState.Pending;

            if (block.number <= proposal.endBlock) return ProposalState.Active;

            if (
                proposal.forVotes <= proposal.againstVotes ||
                proposal.forVotes < quorumVotes(proposal.startBlock)
            ) return ProposalState.Defeated;

            if (proposal.eta == 0) return ProposalState.Succeeded;
        }

        if (proposal.executed) return ProposalState.Executed;

        if (block.timestamp >= proposal.eta + timelock.GRACE_PERIOD())
            return ProposalState.Expired;

        return ProposalState.Queued;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @dev Sets timelock state variable. Contracts {GovernorAlpha} and
     * {Timelock} have circular dependencies upon each other and constructors
     * cannot be used to set them, hence this function is introduced to set
     * {Timelock} in {GovernorAlpha} after it has been deployed.
     *
     * Requirements:
     * - only guardian can call this function
     */
    function setTimelock(address _timelock) external onlyGuardian {
        require(
            _timelock != address(0),
            "GovernorAlpha::initTimelock: _timelock cannot be zero address"
        );
        timelock = ITimelock(_timelock);
    }

    /**
     * @dev Allows any to make a proposal by depositing {feeAmount} xVader.
     * It accepts targets along with the values, signature and calldatas
     * for the actions to perform if the proposal succeeds.
     *
     * Requirements:
     * - targets, values, signatures and calldatas arrays' lengths must be greater
     *   than zero, less than {proposalMaxOperations} and are the same.
     * - the caller must approve {feeAmount} xVader to this contract prior to call.
     * - the caller must not have an active/pending proposal.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) public returns (uint256 proposalId) {
        require(
            targets.length == values.length &&
                targets.length == signatures.length &&
                targets.length == calldatas.length,
            "GovernorAlpha::propose: proposal function information arity mismatch"
        );
        require(
            targets.length != 0,
            "GovernorAlpha::propose: must provide actions"
        );
        require(
            targets.length <= proposalMaxOperations(),
            "GovernorAlpha::propose: too many actions"
        );

        xVader.transferFrom(msg.sender, feeReceiver, feeAmount);

        uint256 latestProposalId = latestProposalIds[msg.sender];
        if (latestProposalId != 0) {
            ProposalState proposersLatestProposalState = state(
                latestProposalId
            );
            require(
                proposersLatestProposalState != ProposalState.Active,
                "GovernorAlpha::propose: one live proposal per proposer, found an already active proposal"
            );
            require(
                proposersLatestProposalState != ProposalState.Pending,
                "GovernorAlpha::propose: one live proposal per proposer, found an already pending proposal"
            );
        }

        uint256 startBlock = block.number + votingDelay();
        uint256 endBlock = startBlock + votingPeriod();

        proposalId = ++proposalCount;
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.signatures = signatures;
        newProposal.calldatas = calldatas;
        newProposal.startBlock = startBlock;
        newProposal.endBlock = endBlock;

        latestProposalIds[msg.sender] = proposalId;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            signatures,
            calldatas,
            startBlock,
            endBlock,
            description
        );
    }

    /**
     * @dev Queues a proposal by setting the hashes of its actions in {Timelock} contract.
     * It also determines 'eta' for the proposal by adding timestamp to {delay} in {Timelock}
     * and sets it against the proposal in question.
     *
     * Requirements:
     * - the proposal in question must have succeeded either through majority for-votes
     *   or has been vetoed in its favour.
     */
    function queue(uint256 proposalId) public {
        require(
            state(proposalId) == ProposalState.Succeeded,
            "GovernorAlpha::queue: proposal can only be queued if it is succeeded"
        );
        Proposal storage proposal = proposals[proposalId];
        uint256 eta = block.timestamp + timelock.delay();

        uint256 length = proposal.targets.length;
        for (uint256 i = 0; i < length; i++) {
            _queueOrRevert(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                eta
            );
        }
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    /**
     * @dev Executes a proposal after it has been queued and cool-off time has elapsed.
     * It sets the {executed} status of the proposal to 'true'.
     *
     * Requirements:
     * - the proposal in question must have been quened and cool-off time has elapsed
     * - none of the actions of the proposal revert upon execution
     */
    function execute(uint256 proposalId) public payable {
        require(
            state(proposalId) == ProposalState.Queued,
            "GovernorAlpha::execute: proposal can only be executed if it is queued"
        );
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        uint256 length = proposal.targets.length;
        for (uint256 i = 0; i < length; i++) {
            timelock.executeTransaction{value: proposal.values[i]}(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }
        emit ProposalExecuted(proposalId);
    }

    /**
     * @dev Casts vote by {msg.sender}.
     * It calls the internal function `_castVote` to perform vote casting.
     */
    function castVote(uint256 proposalId, bool support) public {
        return _castVote(msg.sender, proposalId, support);
    }

    /**
     * @dev Called by a relayer to cast vote by a message signer.
     *
     * Requirements:
     * - {signatory} retrieved must not be a zero address
     */
    function castVoteBySig(
        uint256 proposalId,
        bool support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                getChainId(),
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(BALLOT_TYPEHASH, proposalId, support)
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        address signatory = ecrecover(digest, v, r, s);

        require(
            signatory != address(0),
            "GovernorAlpha::castVoteBySig: invalid signature"
        );

        return _castVote(signatory, proposalId, support);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
     * @dev Changes the {feeReceiver}.
     *
     * Requirements:
     * - only guardian can call
     */
    function changeFeeReceiver(address feeReceiver_) external onlyGuardian {
        emit FeeReceiverChanged(feeReceiver, feeReceiver_);
        feeReceiver = feeReceiver_;
    }

    /**
     * @dev Changes the {feeAmount}.
     *
     * Requirements:
     * - only guardian can call
     */
    function changeFeeAmount(uint256 feeAmount_) external onlyGuardian {
        emit FeeAmountChanged(feeAmount, feeAmount_);
        feeAmount = feeAmount_;
    }

    /**
     * @dev Allows vetoeing of a proposal in favor or against it.
     * It also queues a proposal if it has been vetoed in favor of it and.
     * sets the veto status of the proposal.
     *
     * Requirements:
     * - can only be called by {council}
     * - proposal being vetoed must be active or pending
     * - none of the actions in proposal being vetoed point to the contract
     *   itself. This to restrict council from vetoing a proposal intended
     *   to change council.
     */
    function veto(uint256 proposalId, bool support) external onlyCouncil {
        ProposalState _state = state(proposalId);
        require(
            _state == ProposalState.Active || _state == ProposalState.Pending,
            "GovernorAlpha::veto: Proposal can only be vetoed when active"
        );

        Proposal storage proposal = proposals[proposalId];
        address[] memory _targets = proposal.targets;
        for (uint256 i = 0; i < _targets.length; i++) {
            if (_targets[i] == address(this)) {
                revert(
                    "GovernorAlpha::veto: council cannot veto on proposal having action with address(this) as target"
                );
            }
        }

        VetoStatus storage _vetoStatus = proposal.vetoStatus;
        _vetoStatus.hasBeenVetoed = true;
        _vetoStatus.support = support;

        if (support) {
            queue(proposalId);
        }

        emit ProposalVetoed(proposalId, support);
    }

    /**
     * @dev Changes the {council}.
     *
     * Requirements:
     * - can only be called by {Timelock} contract through a non-vetoeable proposal
     */
    function changeCouncil(address council_) external onlyTimelock {
        emit CouncilChanged(council, council_);
        council = council_;
    }

    /**
     * @dev Cancels the proposal with id {proposalId}.
     * It also sets the {canceled} property of {Proposal} to `true` and
     * removes the proposal's corresponding actions from {Timelock} contract.
     *
     * Requirements:
     * - proposal must not be already executed
     */
    function cancel(uint256 proposalId) public onlyGuardian {
        ProposalState _state = state(proposalId);
        require(
            _state != ProposalState.Executed,
            "GovernorAlpha::cancel: cannot cancel executed proposal"
        );

        Proposal storage proposal = proposals[proposalId];
        proposal.canceled = true;
        uint256 length = proposal.targets.length;
        for (uint256 i = 0; i < length; i++) {
            timelock.cancelTransaction(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }

        emit ProposalCanceled(proposalId);
    }

    /**
     * @dev Calls {acceptAdmin} on {Timelock} contract and makes the current contract
     * the admin of {Timelock} contract.
     *
     * Requirements:
     * - only guardian can call it
     * - current contract must be the `pendingAdmin` in {Timelock} contract
     */
    function __acceptAdmin() public onlyGuardian {
        timelock.acceptAdmin();
    }

    /**
     * @dev Gives up the guardian role associated with the contract.
     *
     * Requirements:
     * - only callable by guardian
     */
    function __abdicate() public onlyGuardian {
        guardian = address(0);
    }

    /**
     * @dev Queues the transaction to set `pendingAdmin` in {Timelock}.
     *
     * Requirements:
     * - only callable by guardian
     */
    function __queueSetTimelockPendingAdmin(
        address newPendingAdmin,
        uint256 eta
    ) public onlyGuardian {
        timelock.queueTransaction(
            address(timelock),
            0,
            "setPendingAdmin(address)",
            abi.encode(newPendingAdmin),
            eta
        );
    }

    /**
     * @dev Executes the transaction to set `pendingAdmin` in {Timelock}.
     *
     * Requirements:
     * - only callable by guardian
     */
    function __executeSetTimelockPendingAdmin(
        address newPendingAdmin,
        uint256 eta
    ) public onlyGuardian {
        timelock.executeTransaction(
            address(timelock),
            0,
            "setPendingAdmin(address)",
            abi.encode(newPendingAdmin),
            eta
        );
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @dev Queues a transaction in {Timelock}.
     *
     * Requirements:
     * - only callable by guardian
     * - transaction is not already queued in {Timelock}
     */
    function _queueOrRevert(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) internal {
        require(
            !timelock.queuedTransactions(
                keccak256(abi.encode(target, value, signature, data, eta))
            ),
            "GovernorAlpha::_queueOrRevert: proposal action already queued at eta"
        );
        timelock.queueTransaction(target, value, signature, data, eta);
    }

    /**
     * @dev Casts vote against proposal with id {proposalId}.
     * It gets the voting weight of voter from {xVader} token contract corresponding to
     * the blocknumber when proposal started and adds those votes to either
     * {forVotes} or {againstVotes} property of {Proposal} depending upon if
     * the voter is voting in favor of or against the proposal.
     *
     * Requirements:
     * - proposal being voted must be active
     * - voter has not already voted against the proposal
     */
    function _castVote(
        address voter,
        uint256 proposalId,
        bool support
    ) internal {
        require(
            state(proposalId) == ProposalState.Active,
            "GovernorAlpha::_castVote: voting is closed"
        );

        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];

        require(
            !receipt.hasVoted,
            "GovernorAlpha::_castVote: voter already voted"
        );

        // optimistically casting to uint224 as xVader contract performs the checks for
        // votes to not overflow uint224.
        uint224 votes = uint224(xVader.getPastVotes(voter, proposal.startBlock));

        if (support) {
            proposal.forVotes = proposal.forVotes + votes;
        } else {
            proposal.againstVotes = proposal.againstVotes + votes;
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        emit VoteCast(voter, proposalId, support, votes);
    }

    // gets the chainid from current network
    function getChainId() internal view returns (uint256 chainId) {
        assembly {
            chainId := chainid()
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    // ensures only {guardian} is able to a particular function.
    function _onlyGuardian() private view {
        require(
            msg.sender == guardian,
            "GovernorAlpha::_onlyGuardian: only guardian can call"
        );
    }

    // ensures only {timelock} is able to a particular function.
    function _onlyTimelock() private view {
        require(
            msg.sender == address(timelock),
            "GovernorAlpha::_onlyTimelock: only timelock can call"
        );
    }

    // ensures only {council} is able to a particular function.
    function _onlyCouncil() private view {
        require(
            msg.sender == council,
            "GovernorAlpha::_onlyCouncil: only council can call"
        );
    }

    /* ========== MODIFIERS ========== */

    /**
     * @dev Throws if invoked by anyone else other than the {guardian}
     */
    modifier onlyGuardian() {
        _onlyGuardian();
        _;
    }

    /**
     * @dev Throws if invoked by anyone else other than the {timelock}
     */
    modifier onlyTimelock() {
        _onlyTimelock();
        _;
    }

    /**
     * @dev Throws if invoked by anyone else other than the {council}
     */
    modifier onlyCouncil() {
        _onlyCouncil();
        _;
    }
}

interface IVaderPoolV2 is IBasePoolV2, IERC721 {
    /* ========== STRUCTS ========== */
    /* ========== FUNCTIONS ========== */

    function cumulativePrices(
        IERC20 foreignAsset
    ) external view returns (
        uint256 price0CumulativeLast,
        uint256 price1CumulativeLast,
        uint32 blockTimestampLast
    );

    function mintSynth(
        IERC20 foreignAsset,
        uint256 nativeDeposit,
        address from,
        address to
    ) external returns (uint256 amountSynth);

    function burnSynth(
        IERC20 foreignAsset,
        uint256 synthAmount,
        address to
    ) external returns (uint256 amountNative);

    function mintFungible(
        IERC20 foreignAsset,
        uint256 nativeDeposit,
        uint256 foreignDeposit,
        address from,
        address to
    ) external returns (uint256 liquidity);

    function burnFungible(
        IERC20 foreignAsset,
        uint256 liquidity,
        address to
    ) external returns (uint256 amountNative, uint256 amountForeign);

    function burn(uint256 id, address to)
        external
        returns (
            uint256 amountNative,
            uint256 amountForeign,
            uint256 coveredLoss
        );

    function toggleQueue() external;

    function setTokenSupport(IERC20 foreignAsset, bool support) external;

    function setFungibleTokenSupport(IERC20 foreignAsset) external;

    /* ========== EVENTS ========== */

    event QueueActive(bool activated);
}

contract Synth is ISynth, ProtocolConstants, ERC20, Ownable {
    /* ========== CONSTRUCTOR ========== */

    constructor(IERC20Extended token)
        ERC20(_calculateName(token), _calculateSymbol(token))
    {}

    /* ========== VIEWS ========== */

    function _calculateName(IERC20Extended token)
        internal
        view
        returns (string memory)
    {
        return _combine(token.name(), " - vSynth");
    }

    function _calculateSymbol(IERC20Extended token)
        internal
        view
        returns (string memory)
    {
        return _combine(token.symbol(), ".v");
    }

    function _combine(string memory a, string memory b)
        internal
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(a, b));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function mint(address to, uint256 amount) external override onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external override onlyOwner {
        _burn(msg.sender, amount);
    }
}

interface ISynthFactory {
    function synths(IERC20 token) external view returns (ISynth);

    function createSynth(IERC20Extended token) external returns (ISynth);
}

interface ILPWrapper {
    function tokens(IERC20 foreignAsset) external view returns (IERC20Extended);

    function createWrapper(IERC20 foreignAsset) external;
}

interface ILPToken {
    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;
}

contract VaderBond is Ownable, ReentrancyGuard {
    // using FixedPoint for FixedPoint.uq112x112;
    using SafeERC20 for IERC20;
    using SafeMath for uint;

    enum PARAMETER {
        VESTING,
        PAYOUT,
        DEBT
    }

    event SetBondTerms(PARAMETER indexed param, uint input);
    event SetAdjustment(bool add, uint rate, uint target, uint buffer);
    event BondCreated(uint deposit, uint payout, uint expires);
    event BondRedeemed(address indexed recipient, uint payout, uint remaining);
    event BondPriceChanged(uint internalPrice, uint debtRatio);
    event ControlVariableAdjustment(uint initialBCV, uint newBCV, uint adjustment, bool addition);
    event TreasuryChanged(address treasury);

    uint8 private immutable PRINCIPAL_TOKEN_DECIMALS;
    uint8 private constant PAYOUT_TOKEN_DECIMALS = 18; // Vader has 18 decimals
    uint private constant MIN_PAYOUT = 10**PAYOUT_TOKEN_DECIMALS / 100; // 0.01
    uint private constant MAX_PERCENT_VESTED = 1e4; // 1 = 0.01%, 10000 = 100%
    uint private constant MAX_PAYOUT_DENOM = 1e5; // 100 = 0.1%, 100000 = 100%

    IERC20 public immutable payoutToken; // token paid for principal
    IERC20 public immutable principalToken; // inflow token
    ITreasury public treasury; // pays for and receives principal

    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // stores adjustment to BCV data

    mapping(address => Bond) public bondInfo; // stores bond information for depositors

    uint public totalDebt; // total value of outstanding bonds; used for pricing
    uint public lastDecay; // reference block for debt decay

    // Info for creating new bonds
    struct Terms {
        uint controlVariable; // scaling variable for price
        uint vestingTerm; // in blocks
        uint minPrice; // vs principal value
        uint maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint maxDebt; // max debt, same decimals with payout token
    }
    // Info for bond holder
    struct Bond {
        uint payout; // payout token remaining to be paid
        uint vesting; // Blocks left to vest
        uint lastBlock; // Last interaction
    }
    // Info for incremental adjustments to control variable
    struct Adjust {
        bool add; // addition or subtraction
        uint rate; // increment
        uint target; // BCV when adjustment finished
        uint buffer; // minimum length (in blocks) between adjustments
        uint lastBlock; // block when last adjustment made
    }

    constructor(
        address _treasury,
        address _payoutToken,
        address _principalToken
    ) {
        require(_treasury != address(0), "treasury = zero");
        treasury = ITreasury(_treasury);
        require(_payoutToken != address(0), "payout token = zero");
        payoutToken = IERC20(_payoutToken);
        require(_principalToken != address(0), "principal token = zero");
        principalToken = IERC20(_principalToken);

        PRINCIPAL_TOKEN_DECIMALS = IERC20Metadata(_principalToken).decimals();
    }

    /**
     *  @notice initializes bond parameters
     *  @param _controlVariable uint
     *  @param _vestingTerm uint
     *  @param _minPrice uint
     *  @param _maxPayout uint
     *  @param _maxDebt uint
     *  @param _initialDebt uint
     */
    function initializeBond(
        uint _controlVariable,
        uint _vestingTerm,
        uint _minPrice,
        uint _maxPayout,
        uint _maxDebt,
        uint _initialDebt
    ) external onlyOwner {
        require(terms.controlVariable == 0, "initialized");

        require(_controlVariable > 0, "cv = 0");
        // roughly 36 hours (262 blocks / hour)
        require(_vestingTerm >= 10000, "vesting < 10000");
        // max payout must be < 1% of total supply of payout token
        require(_maxPayout <= MAX_PAYOUT_DENOM / 100, "max payout > 1%");

        terms = Terms({
            controlVariable: _controlVariable,
            vestingTerm: _vestingTerm,
            minPrice: _minPrice,
            maxPayout: _maxPayout,
            maxDebt: _maxDebt
        });

        totalDebt = _initialDebt;
        lastDecay = block.number;
    }

    /**
     *  @notice set parameters for new bonds
     *  @param _param PARAMETER
     *  @param _input uint
     */
    function setBondTerms(PARAMETER _param, uint _input) external onlyOwner {
        if (_param == PARAMETER.VESTING) {
            // roughly 36 hours (262 blocks / hour)
            require(_input >= 10000, "vesting < 10000");
            terms.vestingTerm = _input;
        } else if (_param == PARAMETER.PAYOUT) {
            // max payout must be < 1% of total supply of payout token
            require(_input <= MAX_PAYOUT_DENOM / 100, "max payout > 1%");
            terms.maxPayout = _input;
        } else if (_param == PARAMETER.DEBT) {
            terms.maxDebt = _input;
        }
        emit SetBondTerms(_param, _input);
    }

    /**
     *  @notice set control variable adjustment
     *  @param _add bool
     *  @param _rate uint
     *  @param _target uint
     *  @param _buffer uint
     */
    function setAdjustment(
        bool _add,
        uint _rate,
        uint _target,
        uint _buffer
    ) external onlyOwner {
        require(_rate <= terms.controlVariable.mul(3) / 100, "rate > 3%");
        adjustment = Adjust({add: _add, rate: _rate, target: _target, buffer: _buffer, lastBlock: block.number});
        emit SetAdjustment(_add, _rate, _target, _buffer);
    }

    /**
     *  @notice deposit bond
     *  @param _amount uint
     *  @param _maxPrice uint
     *  @param _depositor address
     *  @return uint
     *  @dev Deposit resets vesting term for _depositor
     */
    function deposit(
        uint _amount,
        uint _maxPrice,
        address _depositor
    ) external nonReentrant returns (uint) {
        require(_depositor != address(0), "depositor = zero");

        decayDebt();
        require(totalDebt <= terms.maxDebt, "max debt");
        require(_maxPrice >= bondPrice(), "bond price > max");

        uint value = treasury.valueOfToken(address(principalToken), _amount);
        uint payout = payoutFor(value);

        require(payout >= MIN_PAYOUT, "payout < min");
        // size protection because there is no slippage
        require(payout <= maxPayout(), "payout > max");

        principalToken.safeTransferFrom(msg.sender, address(this), _amount);
        principalToken.approve(address(treasury), _amount);
        treasury.deposit(address(principalToken), _amount, payout);

        totalDebt = totalDebt.add(value);

        bondInfo[_depositor] = Bond({
            payout: bondInfo[_depositor].payout.add(payout),
            vesting: terms.vestingTerm,
            lastBlock: block.number
        });

        emit BondCreated(_amount, payout, block.number.add(terms.vestingTerm));

        uint price = bondPrice();
        // remove floor if price above min
        if (price > terms.minPrice && terms.minPrice > 0) {
            terms.minPrice = 0;
        }

        emit BondPriceChanged(price, debtRatio());

        adjust(); // control variable is adjusted
        return payout;
    }

    /**
     *  @notice redeem bond for user
     *  @return uint
     */
    function redeem(address _depositor) external nonReentrant returns (uint) {
        Bond memory info = bondInfo[_depositor];
        uint percentVested = percentVestedFor(_depositor); // (blocks since last interaction / vesting term remaining)

        if (percentVested >= MAX_PERCENT_VESTED) {
            // if fully vested
            delete bondInfo[_depositor]; // delete user info
            emit BondRedeemed(_depositor, info.payout, 0); // emit bond data
            payoutToken.transfer(_depositor, info.payout);
            return info.payout;
        } else {
            // if unfinished
            // calculate payout vested
            uint payout = info.payout.mul(percentVested) / MAX_PERCENT_VESTED;

            // store updated deposit info
            bondInfo[_depositor] = Bond({
                payout: info.payout.sub(payout),
                vesting: info.vesting.sub(block.number.sub(info.lastBlock)),
                lastBlock: block.number
            });

            emit BondRedeemed(_depositor, payout, bondInfo[_depositor].payout);
            payoutToken.transfer(_depositor, payout);
            return payout;
        }
    }

    /**
     *  @notice makes incremental adjustment to control variable
     */
    function adjust() private {
        uint blockCanAdjust = adjustment.lastBlock.add(adjustment.buffer);
        if (adjustment.rate != 0 && block.number >= blockCanAdjust) {
            uint initial = terms.controlVariable;
            if (adjustment.add) {
                terms.controlVariable = terms.controlVariable.add(adjustment.rate);
                if (terms.controlVariable >= adjustment.target) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable.sub(adjustment.rate);
                if (terms.controlVariable <= adjustment.target) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastBlock = block.number;
            emit ControlVariableAdjustment(initial, terms.controlVariable, adjustment.rate, adjustment.add);
        }
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay uint
     */
    function debtDecay() public view returns (uint decay) {
        uint blocksSinceLast = block.number.sub(lastDecay);
        decay = totalDebt.mul(blocksSinceLast).div(terms.vestingTerm);
        if (decay > totalDebt) {
            decay = totalDebt;
        }
    }

    /**
     *  @notice reduce total debt
     */
    function decayDebt() private {
        totalDebt = totalDebt.sub(debtDecay());
        lastDecay = block.number;
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns (uint) {
        return totalDebt.sub(debtDecay());
    }

    /**
     *  @notice calculate current ratio of debt to payout token supply
     *  @notice protocols using DAO should be careful when quickly adding large %s to total supply
     *  @return uint
     */
    function debtRatio() public view returns (uint) {
        // TODO: use fraction?
        // return
        //     FixedPoint
        //         .fraction(currentDebt().mul(10**PAYOUT_TOKEN_DECIMALS), payoutToken.totalSupply())
        //         .decode112with18() / 1e18;
        // NOTE: debt ratio is scaled up by 1e18
        // NOTE: fails if payoutToken.totalSupply() == 0
        return currentDebt().mul(1e18).div(payoutToken.totalSupply());
    }

    /**
     *  @notice calculate current bond premium
     *  @return price uint
     *  @dev price = 10 ** principal token decimals = 1 principal token buys 1 bond
     */
    function bondPrice() public view returns (uint price) {
        // NOTE: debt ratio scaled up with 1e18, so divide by 1e18
        price = terms.controlVariable.mul(debtRatio()) / 1e18;
        if (price < terms.minPrice) {
            price = terms.minPrice;
        }
    }

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() public view returns (uint) {
        return payoutToken.totalSupply().mul(terms.maxPayout) / MAX_PAYOUT_DENOM;
    }

    /**
     *  @notice calculate total interest due for new bond
     *  @param _value uint
     *  @return uint
     */
    function payoutFor(uint _value) public view returns (uint) {
        // TODO: use fraction?
        // NOTE: scaled up by 1e7
        // return FixedPoint.fraction(_value, bondPrice()).decode112with18() / 1e11;

        /*
        B = amount of bond to payout
        A = amount of principal token in
        P = amount of principal token to pay to get 1 bond

        B = A / P
        */
        // NOTE: decimals of value must match payout token decimals
        // NOTE: bond price must match principal token decimals
        return _value.mul(10**PRINCIPAL_TOKEN_DECIMALS).div(bondPrice());
    }

    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param _depositor address
     *  @return percentVested uint
     */
    function percentVestedFor(address _depositor) public view returns (uint percentVested) {
        Bond memory bond = bondInfo[_depositor];
        uint blocksSinceLast = block.number.sub(bond.lastBlock);
        uint vesting = bond.vesting;
        if (vesting > 0) {
            percentVested = blocksSinceLast.mul(MAX_PERCENT_VESTED).div(vesting);
        }
        // default percentVested = 0
    }

    /**
     *  @notice calculate amount of payout token available for claim by depositor
     *  @param _depositor address
     *  @return uint
     */
    function pendingPayoutFor(address _depositor) external view returns (uint) {
        uint percentVested = percentVestedFor(_depositor);
        uint payout = bondInfo[_depositor].payout;
        if (percentVested >= MAX_PERCENT_VESTED) {
            return payout;
        } else {
            return payout.mul(percentVested) / MAX_PERCENT_VESTED;
        }
    }

    /**
     *  @notice owner can update treasury address
     *  @param _treasury address
     *  @dev allow new treasury to be zero address
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(treasury), "no change");
        treasury = ITreasury(_treasury);
        emit TreasuryChanged(_treasury);
    }

    /**
     *  @notice allows owner to send lost tokens to owner
     *  @param _token address
     */
    function recoverLostToken(address _token) external onlyOwner {
        require(_token != address(principalToken), "protected");
        require(_token != address(payoutToken), "protected");
        IERC20(_token).safeTransfer(owner, IERC20(_token).balanceOf(address(this)));
    }
}
interface IERC721Metadata is IERC721 {
    /**
     * @dev Returns the token collection name.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the token collection symbol.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the Uniform Resource Identifier (URI) for `tokenId` token.
     */
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

library Strings {
    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0x00";
        }
        uint256 temp = value;
        uint256 length = 0;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }
        return toHexString(value, length);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }
}

interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be reverted.
     *
     * The selector can be obtained in Solidity with `IERC721.onERC721Received.selector`.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

contract ERC721 is Context, ERC165, IERC721, IERC721Metadata {
    using Address for address;
    using Strings for uint256;

    // Token name
    string private _name;

    // Token symbol
    string private _symbol;

    // Mapping from token ID to owner address
    mapping(uint256 => address) private _owners;

    // Mapping owner address to token count
    mapping(address => uint256) private _balances;

    // Mapping from token ID to approved address
    mapping(uint256 => address) private _tokenApprovals;

    // Mapping from owner to operator approvals
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /**
     * @dev Initializes the contract by setting a `name` and a `symbol` to the token collection.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IERC721-balanceOf}.
     */
    function balanceOf(address owner) public view virtual override returns (uint256) {
        require(owner != address(0), "ERC721: balance query for the zero address");
        return _balances[owner];
    }

    /**
     * @dev See {IERC721-ownerOf}.
     */
    function ownerOf(uint256 tokenId) public view virtual override returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ERC721: owner query for nonexistent token");
        return owner;
    }

    /**
     * @dev See {IERC721Metadata-name}.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev See {IERC721Metadata-symbol}.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        string memory baseURI = _baseURI();
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, tokenId.toString())) : "";
    }

    /**
     * @dev Base URI for computing {tokenURI}. If set, the resulting URI for each
     * token will be the concatenation of the `baseURI` and the `tokenId`. Empty
     * by default, can be overriden in child contracts.
     */
    function _baseURI() internal view virtual returns (string memory) {
        return "";
    }

    /**
     * @dev See {IERC721-approve}.
     */
    function approve(address to, uint256 tokenId) public virtual override {
        address owner = ERC721.ownerOf(tokenId);
        require(to != owner, "ERC721: approval to current owner");

        require(
            _msgSender() == owner || isApprovedForAll(owner, _msgSender()),
            "ERC721: approve caller is not owner nor approved for all"
        );

        _approve(to, tokenId);
    }

    /**
     * @dev See {IERC721-getApproved}.
     */
    function getApproved(uint256 tokenId) public view virtual override returns (address) {
        require(_exists(tokenId), "ERC721: approved query for nonexistent token");

        return _tokenApprovals[tokenId];
    }

    /**
     * @dev See {IERC721-setApprovalForAll}.
     */
    function setApprovalForAll(address operator, bool approved) public virtual override {
        require(operator != _msgSender(), "ERC721: approve to caller");

        _operatorApprovals[_msgSender()][operator] = approved;
        emit ApprovalForAll(_msgSender(), operator, approved);
    }

    /**
     * @dev See {IERC721-isApprovedForAll}.
     */
    function isApprovedForAll(address owner, address operator) public view virtual override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    /**
     * @dev See {IERC721-transferFrom}.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {
        //solhint-disable-next-line max-line-length
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: transfer caller is not owner nor approved");

        _transfer(from, to, tokenId);
    }

    /**
     * @dev See {IERC721-safeTransferFrom}.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {
        safeTransferFrom(from, to, tokenId, "");
    }

    /**
     * @dev See {IERC721-safeTransferFrom}.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) public virtual override {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: transfer caller is not owner nor approved");
        _safeTransfer(from, to, tokenId, _data);
    }

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * `_data` is additional data, it has no specified format and it is sent in call to `to`.
     *
     * This internal function is equivalent to {safeTransferFrom}, and can be used to e.g.
     * implement alternative mechanisms to perform token transfer, such as signature-based.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function _safeTransfer(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) internal virtual {
        _transfer(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, _data), "ERC721: transfer to non ERC721Receiver implementer");
    }

    /**
     * @dev Returns whether `tokenId` exists.
     *
     * Tokens can be managed by their owner or approved accounts via {approve} or {setApprovalForAll}.
     *
     * Tokens start existing when they are minted (`_mint`),
     * and stop existing when they are burned (`_burn`).
     */
    function _exists(uint256 tokenId) internal view virtual returns (bool) {
        return _owners[tokenId] != address(0);
    }

    /**
     * @dev Returns whether `spender` is allowed to manage `tokenId`.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view virtual returns (bool) {
        require(_exists(tokenId), "ERC721: operator query for nonexistent token");
        address owner = ERC721.ownerOf(tokenId);
        return (spender == owner || getApproved(tokenId) == spender || isApprovedForAll(owner, spender));
    }

    /**
     * @dev Safely mints `tokenId` and transfers it to `to`.
     *
     * Requirements:
     *
     * - `tokenId` must not exist.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function _safeMint(address to, uint256 tokenId) internal virtual {
        _safeMint(to, tokenId, "");
    }

    /**
     * @dev Same as {xref-ERC721-_safeMint-address-uint256-}[`_safeMint`], with an additional `data` parameter which is
     * forwarded in {IERC721Receiver-onERC721Received} to contract recipients.
     */
    function _safeMint(
        address to,
        uint256 tokenId,
        bytes memory _data
    ) internal virtual {
        _mint(to, tokenId);
        require(
            _checkOnERC721Received(address(0), to, tokenId, _data),
            "ERC721: transfer to non ERC721Receiver implementer"
        );
    }

    /**
     * @dev Mints `tokenId` and transfers it to `to`.
     *
     * WARNING: Usage of this method is discouraged, use {_safeMint} whenever possible
     *
     * Requirements:
     *
     * - `tokenId` must not exist.
     * - `to` cannot be the zero address.
     *
     * Emits a {Transfer} event.
     */
    function _mint(address to, uint256 tokenId) internal virtual {
        require(to != address(0), "ERC721: mint to the zero address");
        require(!_exists(tokenId), "ERC721: token already minted");

        _beforeTokenTransfer(address(0), to, tokenId);

        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }

    /**
     * @dev Destroys `tokenId`.
     * The approval is cleared when the token is burned.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     *
     * Emits a {Transfer} event.
     */
    function _burn(uint256 tokenId) internal virtual {
        address owner = ERC721.ownerOf(tokenId);

        _beforeTokenTransfer(owner, address(0), tokenId);

        // Clear approvals
        _approve(address(0), tokenId);

        _balances[owner] -= 1;
        delete _owners[tokenId];

        emit Transfer(owner, address(0), tokenId);
    }

    /**
     * @dev Transfers `tokenId` from `from` to `to`.
     *  As opposed to {transferFrom}, this imposes no restrictions on msg.sender.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     *
     * Emits a {Transfer} event.
     */
    function _transfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual {
        require(ERC721.ownerOf(tokenId) == from, "ERC721: transfer of token that is not own");
        require(to != address(0), "ERC721: transfer to the zero address");

        _beforeTokenTransfer(from, to, tokenId);

        // Clear approvals from the previous owner
        _approve(address(0), tokenId);

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    /**
     * @dev Approve `to` to operate on `tokenId`
     *
     * Emits a {Approval} event.
     */
    function _approve(address to, uint256 tokenId) internal virtual {
        _tokenApprovals[tokenId] = to;
        emit Approval(ERC721.ownerOf(tokenId), to, tokenId);
    }

    /**
     * @dev Internal function to invoke {IERC721Receiver-onERC721Received} on a target address.
     * The call is not executed if the target address is not a contract.
     *
     * @param from address representing the previous owner of the given token ID
     * @param to target address that will receive the tokens
     * @param tokenId uint256 ID of the token to be transferred
     * @param _data bytes optional data to send along with the call
     * @return bool whether the call correctly returned the expected magic value
     */
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) private returns (bool) {
        if (to.isContract()) {
            try IERC721Receiver(to).onERC721Received(_msgSender(), from, tokenId, _data) returns (bytes4 retval) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert("ERC721: transfer to non ERC721Receiver implementer");
                } else {
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        } else {
            return true;
        }
    }

    /**
     * @dev Hook that is called before any token transfer. This includes minting
     * and burning.
     *
     * Calling conditions:
     *
     * - When `from` and `to` are both non-zero, ``from``'s `tokenId` will be
     * transferred to `to`.
     * - When `from` is zero, `tokenId` will be minted for `to`.
     * - When `to` is zero, ``from``'s `tokenId` will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual {}
}
/*
 * @dev Implementation of {BasePoolV2} contract.
 *
 * The BasePoolV2 contract keeps track of all the Vader pools in the form of
 * pairs. Each pair tracked through {pairInfo} mapping and is mapped against the
 * foreign asset for which the pair is created.
 *
 * Has function to deposited liquidity to any of pair by specifying the mapped
 * foreign asset against the pair.
 *
 * The minted liquidity is associated with a position, that is tracked by a minted NFT.
 * The NFT has information about the pair for which it represents the liquidity.
 *
 * The contract allows redeeming of liquidity against a particular pool by burning the
 * associated position representing NFT.
 *
 * The contract allows swapping of native to foreign assets and vice versa within a pair and
 * allows foreign to foreign asset swap across two different pairs.
 *
 * Keeps track of the cumulative prices for both native and foreign assets for
 * pairs and updates them after minting and burning of liquidity, and swapping of assets.
 **/
contract BasePoolV2 is
    IBasePoolV2,
    ProtocolConstants,
    GasThrottle,
    ERC721,
    ReentrancyGuard
{
    /* ========== LIBRARIES ========== */

    // Used for safe token transfers
    using SafeERC20 for IERC20;

    // Used by Uniswap-like TWAP mechanism
    using UQ112x112 for uint224;

    /* ========== STATE VARIABLES ========== */

    // Address of native asset (Vader or USDV).
    IERC20 public immutable override nativeAsset;

    // Denotes what tokens are actively supported by the system
    mapping(IERC20 => bool) public override supported;

    /*
     * @dev A mapping of foreign asset to the pool's pair.
     * Each pair is represents a pool of native and foreign assets and
     * contains data such as the reserves of native and foreign assets and
     * the liquidity units issues against the deposits of these assets.
     **/
    mapping(IERC20 => PairInfo) public pairInfo;

    /*
     * @dev A mapping representing positions of liquidity providers. Each position
     * is an Non-fungible token that is mapped against amounts of native and foreign assets
     * deposited across different pools of pairs the timestamp at which the position
     * is created and the amount of liquidity of a particular pool assigned to the LP.
     *
     * Each position in the mapping is mapped against {positionId}.
     **/
    mapping(uint256 => Position) public positions;

    // A unique id the of the position created when liquidity is added to a pool.
    uint256 public positionId;

    // Address of the router contract (used for restriction)
    address public router;

    /* ========== CONSTRUCTOR ========== */

    /*
     * @dev Initializes the contract by setting address of native asset.
     **/
    constructor(IERC20 _nativeAsset) ERC721("Vader LP", "VLP") {
        require(
            _nativeAsset != IERC20(_ZERO_ADDRESS),
            "BasePoolV2::constructor: Incorrect Arguments"
        );
        nativeAsset = IERC20(_nativeAsset);
    }

    /* ========== VIEWS ========== */

    /*
     * @dev Accepts address of foreign asset {foreignAsset} to determine the pair (pool)
     * and returns reserves amounts of native and foreign assets, and the last timestamp
     * when cumulative prices for these assets were updated.
     **/
    function getReserves(IERC20 foreignAsset)
        public
        view
        returns (
            uint112 reserveNative,
            uint112 reserveForeign,
            uint32 blockTimestampLast
        )
    {
        PairInfo storage pair = pairInfo[foreignAsset];
        (reserveNative, reserveForeign, blockTimestampLast) = (
            pair.reserveNative,
            pair.reserveForeign,
            pair.blockTimestampLast
        );
    }

    /*
     * @dev Accepts {id} of a liquidity position and returns foreign asset's
     * address for that particular liquidity position.
     **/
    function positionForeignAsset(uint256 id)
        external
        view
        override
        returns (IERC20)
    {
        return positions[id].foreignAsset;
    }

    function pairSupply(IERC20 foreignAsset)
        external
        view
        override
        returns (uint256)
    {
        return pairInfo[foreignAsset].totalSupply;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /*
     * @dev Allows depositing of liquidity to a pool/pair by accepting native and foreign assets
     * and mints an NFT to the {to} address which records in {positions} mapping, the amounts
     * of the native and foreign assets deposited and the liquidity units minted against.
     *
     * The pool/pair to accept the native and foreign assets against is determined by {foreignAsset}.
     *
     * Updates the total supply of liquidity units by adding currently minted liquidity units
     * to {pair.totalSupply} of pair/pool.
     *
     * Updates the cumulative prices of native and foreign assets in pool/pair after minting the appropriate
     * liquidity units.
     *
     * Requirements:
     * - Amounts of native and foreign must be approved to the pool prior to calling the `mint` function.
     * - The amount of {liquidity} to be minted must be greater than 0.
     * - The param {foreignAsset} must be a supported token.
     * - Can only be called by Router.
     **/
    function mint(
        IERC20 foreignAsset,
        uint256 nativeDeposit,
        uint256 foreignDeposit,
        address from,
        address to
    )
        external
        override
        nonReentrant
        onlyRouter
        supportedToken(foreignAsset)
        returns (uint256 liquidity)
    {
        (uint112 reserveNative, uint112 reserveForeign, ) = getReserves(
            foreignAsset
        ); // gas savings

        nativeAsset.safeTransferFrom(from, address(this), nativeDeposit);
        foreignAsset.safeTransferFrom(from, address(this), foreignDeposit);

        PairInfo storage pair = pairInfo[foreignAsset];
        uint256 totalLiquidityUnits = pair.totalSupply;
        if (totalLiquidityUnits == 0) liquidity = nativeDeposit;
        else
            liquidity = VaderMath.calculateLiquidityUnits(
                nativeDeposit,
                reserveNative,
                foreignDeposit,
                reserveForeign,
                totalLiquidityUnits
            );

        require(
            liquidity > 0,
            "BasePoolV2::mint: Insufficient Liquidity Provided"
        );

        uint256 id = positionId++;

        pair.totalSupply = totalLiquidityUnits + liquidity;
        _mint(to, id);

        positions[id] = Position(
            foreignAsset,
            block.timestamp,
            liquidity,
            nativeDeposit,
            foreignDeposit
        );

        _update(
            foreignAsset,
            reserveNative + nativeDeposit,
            reserveForeign + foreignDeposit,
            reserveNative,
            reserveForeign
        );

        emit Mint(from, to, nativeDeposit, foreignDeposit);
        emit PositionOpened(from, to, id, liquidity);
    }

    /*
     * @dev Allows redeeming of liquidity units by burning the NFT with {id} associated with the liquidity
     * position.
     *
     * Computes the amounts of native and foreign assets from pool/pair against which the NFT with Id {id}
     * was minted. The computed assets' amounts depends upon current reserves of assets and
     * the liquidity associated with the position, and is transferred to the {to} address.
     *
     * Burns the redeemed NFT token and decreases {pair.totalSupply} by the {liquidity}
     * associated with that NFT token.
     *
     * Updates the cumulative prices for native and foreign assets in pool/pair after transferring the assets
     * to the {to} address.
     *
     * Requirements:
     * - The NFT token being redeemed must be transferred to the contract prior to calling `_burn`.
     * - The amount of native and foreign assets computed for transfer to {to} address must be greater
     *   than 0.
     **/
    function _burn(uint256 id, address to)
        internal
        nonReentrant
        returns (uint256 amountNative, uint256 amountForeign)
    {
        require(
            ownerOf(id) == address(this),
            "BasePoolV2::burn: Incorrect Ownership"
        );

        IERC20 foreignAsset = positions[id].foreignAsset;

        (uint112 reserveNative, uint112 reserveForeign, ) = getReserves(
            foreignAsset
        ); // gas savings

        uint256 liquidity = positions[id].liquidity;

        PairInfo storage pair = pairInfo[foreignAsset];
        uint256 _totalSupply = pair.totalSupply;
        amountNative = (liquidity * reserveNative) / _totalSupply;
        amountForeign = (liquidity * reserveForeign) / _totalSupply;

        require(
            amountNative > 0 && amountForeign > 0,
            "BasePoolV2::burn: Insufficient Liquidity Burned"
        );

        pair.totalSupply = _totalSupply - liquidity;
        _burn(id);

        nativeAsset.safeTransfer(to, amountNative);
        foreignAsset.safeTransfer(to, amountForeign);

        _update(
            foreignAsset,
            reserveNative - amountNative,
            reserveForeign - amountForeign,
            reserveNative,
            reserveForeign
        );

        emit Burn(msg.sender, amountNative, amountForeign, to);
    }

    /*
     * @dev Allows swapping between two foreign assets from two different pools/pairs.
     *
     * It receives amount {foreignAmountIn} in {foreignAssetA} and returns the swapped amount in {foreignAssetB}.
     *
     * The amount {foreignAmountIn} is swapped to the native asset from the pair against {foreignAssetA} and the
     * received native asset is swapped to foreign asset from the pair against {foreignAssetB}.
     *
     * Updates the cumulative prices for native and foreign assets across pools against assets {foreignAssetA} and
     * {foreignAssetB}.
     *
     * Requirements:
     * - The amount {foreignAmountIn} in {foreignAssetA} must be transferred to the contract prior to calling
     *   the function `doubleSwap`.
     * - The intermediary native asset retrieved from first swap must be greater than 0 and the reserve for native asset.
     * - The foreign amount received from second swap must be greater than 0 and the reserve for foreign asset in the pair/pool
     *   against that particular foreign asset.
     * - The params {foreignAssetA} and {foreignAssetB} must be the supported tokens.
     * - Can only be called by Router.
     **/
    function doubleSwap(
        IERC20 foreignAssetA,
        IERC20 foreignAssetB,
        uint256 foreignAmountIn,
        address to
    )
        external
        override
        onlyRouter
        supportedToken(foreignAssetA)
        supportedToken(foreignAssetB)
        nonReentrant
        validateGas
        returns (uint256 foreignAmountOut)
    {
        (uint112 nativeReserve, uint112 foreignReserve, ) = getReserves(
            foreignAssetA
        ); // gas savings

        require(
            foreignReserve + foreignAmountIn <=
                foreignAssetA.balanceOf(address(this)),
            "BasePoolV2::doubleSwap: Insufficient Tokens Provided"
        );

        uint256 nativeAmountOut = VaderMath.calculateSwap(
            foreignAmountIn,
            foreignReserve,
            nativeReserve
        );

        require(
            nativeAmountOut > 0 && nativeAmountOut <= nativeReserve,
            "BasePoolV2::doubleSwap: Swap Impossible"
        );

        _update(
            foreignAssetA,
            nativeReserve - nativeAmountOut,
            foreignReserve + foreignAmountIn,
            nativeReserve,
            foreignReserve
        );

        emit Swap(
            foreignAssetA,
            msg.sender,
            0,
            foreignAmountIn,
            nativeAmountOut,
            0,
            address(this)
        );

        (nativeReserve, foreignReserve, ) = getReserves(foreignAssetB); // gas savings

        foreignAmountOut = VaderMath.calculateSwap(
            nativeAmountOut,
            nativeReserve,
            foreignReserve
        );

        require(
            foreignAmountOut > 0 && foreignAmountOut <= foreignReserve,
            "BasePoolV2::doubleSwap: Swap Impossible"
        );

        _update(
            foreignAssetB,
            nativeReserve + nativeAmountOut,
            foreignReserve - foreignAmountOut,
            nativeReserve,
            foreignReserve
        );

        emit Swap(
            foreignAssetB,
            msg.sender,
            nativeAmountOut,
            0,
            0,
            foreignAmountOut,
            to
        );

        foreignAssetB.safeTransfer(to, foreignAmountOut);
    }

    /*
     * @dev Allows swapping between native and foreign assets from within a single pair/pool determined
     * by {foreignAsset}.
     *
     * It receives the source asset and computes the destination asset and transfers it to the {to} address.
     *
     * Updates the cumulative prices for native and foreign assets for the pair involved after performing swap.
     *
     * Returns the amount of destination tokens resulting from the swap.
     *
     * Requirements:
     * - Param {nativeAmountIn} must be zero and {foreignAmountIn} must be non-zero
     *   if the destination asset in swap is native asset.
     * - Param {foreignAmountIn} must be zero and {nativeAmountIn} must be non zero
     *   if the destination asset in swap is foreign asset.
     * - Param {to} cannot be the addresses of native or foreign assets.
     * - The source asset amount in the swap must be transferred to the pool prior to calling `swap`.
     * - The source asset amount in the swap cannot exceed the source asset's reserve.
     * - The destination asset's amount in the swap must be greater than 0 and not exceed destination
     *   asset's reserve.
     * - The param {foreignAsset} must be a supported token.
     * - Can only be called by Router.
     **/
    function swap(
        IERC20 foreignAsset,
        uint256 nativeAmountIn,
        uint256 foreignAmountIn,
        address to
    )
        external
        override
        onlyRouter
        supportedToken(foreignAsset)
        nonReentrant
        validateGas
        returns (uint256)
    {
        require(
            (nativeAmountIn > 0 && foreignAmountIn == 0) ||
                (nativeAmountIn == 0 && foreignAmountIn > 0),
            "BasePoolV2::swap: Only One-Sided Swaps Supported"
        );
        (uint112 nativeReserve, uint112 foreignReserve, ) = getReserves(
            foreignAsset
        ); // gas savings

        uint256 nativeAmountOut;
        uint256 foreignAmountOut;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            IERC20 _nativeAsset = nativeAsset;
            require(
                to != address(_nativeAsset) && to != address(foreignAsset),
                "BasePoolV2::swap: Invalid Receiver"
            );

            if (foreignAmountIn > 0) {
                nativeAmountOut = VaderMath.calculateSwap(
                    foreignAmountIn,
                    foreignReserve,
                    nativeReserve
                );
                require(
                    nativeAmountOut > 0 && nativeAmountOut <= nativeReserve,
                    "BasePoolV2::swap: Swap Impossible"
                );
                _nativeAsset.safeTransfer(to, nativeAmountOut); // optimistically transfer tokens
            } else {
                foreignAmountOut = VaderMath.calculateSwap(
                    nativeAmountIn,
                    nativeReserve,
                    foreignReserve
                );
                require(
                    foreignAmountOut > 0 && foreignAmountOut <= foreignReserve,
                    "BasePoolV2::swap: Swap Impossible"
                );
                foreignAsset.safeTransfer(to, foreignAmountOut); // optimistically transfer tokens
            }
        }

        _update(
            foreignAsset,
            nativeReserve - nativeAmountOut + nativeAmountIn,
            foreignReserve - foreignAmountOut + foreignAmountIn,
            nativeReserve,
            foreignReserve
        );

        emit Swap(
            foreignAsset,
            msg.sender,
            nativeAmountIn,
            foreignAmountIn,
            nativeAmountOut,
            foreignAmountOut,
            to
        );

        return nativeAmountOut > 0 ? nativeAmountOut : foreignAmountOut;
    }

    /*
     * @dev Allows withdrawing of unaccounted/unrealised foreign asset from the contract.
     *
     * Determines the realised amount of foreign asset from the pair against {foreignAsset}.
     **/
    function rescue(IERC20 foreignAsset) external {
        uint256 foreignBalance = foreignAsset.balanceOf(address(this));
        uint256 reserveForeign = pairInfo[foreignAsset].reserveForeign;

        uint256 unaccounted = foreignBalance - reserveForeign;

        foreignAsset.safeTransfer(msg.sender, unaccounted);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /* ========== INTERNAL FUNCTIONS ========== */

    /*
     * @dev Internally called to update the cumulative prices for native and foreign assets for
     * the pair against {foreignAsset}. The updated prices depend upon the last reserves and
     * updates the reserves for both of the assets corresponding to their
     * current balances along with the timestamp.
     *
     * Requirements:
     * - Params {balanceNative} and {balanceForeign} must not overflow type `uint112`.
     *
     **/
    function _update(
        IERC20 foreignAsset,
        uint256 balanceNative,
        uint256 balanceForeign,
        uint112 reserveNative,
        uint112 reserveForeign
    ) internal {
        require(
            balanceNative <= type(uint112).max &&
                balanceForeign <= type(uint112).max,
            "BasePoolV2::_update: Balance Overflow"
        );
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        PairInfo storage pair = pairInfo[foreignAsset];
        unchecked {
            uint32 timeElapsed = blockTimestamp - pair.blockTimestampLast; // overflow is desired
            if (timeElapsed > 0 && reserveNative != 0 && reserveForeign != 0) {
                // * never overflows, and + overflow is desired
                pair.priceCumulative.nativeLast +=
                    uint256(
                        UQ112x112.encode(reserveForeign).uqdiv(reserveNative)
                    ) *
                    timeElapsed;
                pair.priceCumulative.foreignLast +=
                    uint256(
                        UQ112x112.encode(reserveNative).uqdiv(reserveForeign)
                    ) *
                    timeElapsed;
            }
        }
        pair.reserveNative = uint112(balanceNative);
        pair.reserveForeign = uint112(balanceForeign);
        pair.blockTimestampLast = blockTimestamp;
        emit Sync(foreignAsset, balanceNative, balanceForeign);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /*
     * @dev Private function that returns if the param {token} is a supported token
     * or not.
     **/
    function _supportedToken(IERC20 token) private view {
        require(
            supported[token],
            "BasePoolV2::_supportedToken: Unsupported Token"
        );
    }

    /*
     * @dev Private function that returns if {msg.sender} is a Router or not.
     **/
    function _onlyRouter() private view {
        require(
            msg.sender == router,
            "BasePoolV2::_onlyRouter: Only Router is allowed to call"
        );
    }

    /* ========== MODIFIERS ========== */

    /*
     * @dev Modifier that only allows continuation of execution
     * if {msg.sender} is Router.
     **/
    modifier onlyRouter() {
        _onlyRouter();
        _;
    }

    /*
     * @dev Modifier that only allows continuation of exectuion if the param
     * {token} is a supported token.
     **/
    modifier supportedToken(IERC20 token) {
        _supportedToken(token);
        _;
    }
}

/*
 * @dev Implementation of {BasePool} contract.
 *
 * The BasePool contract represents pool of two assets termed as native and
 * foreign assets. The functionality in this contract allows depositing of both
 * of these assets to mint liquidity. Minted liquidity is associated with a
 * position which is represented by an NFT token.
 *
 * The contract allows burning of NFT and in turn redeems the associated liquidity,
 * transferring out underlying assets to the LP.
 *
 * The contract allows swapping of both native and foreign assets among themselves.
 *
 * Keeps track of the cumulative prices for both native and foreign assets and updates
 * them after minting and burning of liquidity, and swapping of assets.
 **/
contract BasePool is IBasePool, GasThrottle, ERC721, Ownable, ReentrancyGuard {
    /* ========== LIBRARIES ========== */

    // Used for safe token transfers
    using SafeERC20 for IERC20;

    // Used by Uniswap-like TWAP mechanism
    using UQ112x112 for uint224;

    /* ========== STATE VARIABLES ========== */

    // Address of native asset (Vader or USDV).
    IERC20 public immutable nativeAsset;

    // Address of foreign asset with which the native asset is paired in the pool.
    IERC20 public immutable foreignAsset;

    // Cumulative price of native asset.
    uint256 public priceNativeCumulativeLast;

    // Cumulative price of foreign asset.
    uint256 public priceForeignCumulativeLast;

    /*
     * @dev A mapping representing positions of liquidity providers. Each position
     * is an Non-fungible token that is mapped against amounts of native and foreign assets
     * deposited, the timestamp at which the position is created and the amount of
     * liquidity assigned to the LP.
     *
     * Each position in the mapping is mapped against {positionId}.
     **/
    mapping(uint256 => Position) public positions;

    // A unique id the of the position created when liquidity is added to the pool.
    uint256 public positionId;

    // Total amount of liquidity units minted.
    uint256 public totalSupply;

    // Name of the contract.
    string private _name;

    // Total amount of the native asset realised by the contract.
    uint112 private _reserveNative; // uses single storage slot, accessible via getReserves

    // Total amount of the foreign asset realised by the contract.
    uint112 private _reserveForeign; // uses single storage slot, accessible via getReserves

    // Last timestamp at which the cumulative prices for native and foreign assets were updated.
    uint32 private _blockTimestampLast; // uses single storage slot, accessible via getReserves

    /* ========== CONSTRUCTOR ========== */

    /*
     * @dev Initialized the contract state setting the addresses for native and foreign assets.
     *
     * Also computes the name of the contract and stores it in the contract's state.
     **/
    constructor(IERC20Extended _nativeAsset, IERC20Extended _foreignAsset)
        ERC721("Vader LP", "VLP")
    {
        nativeAsset = IERC20(_nativeAsset);
        foreignAsset = IERC20(_foreignAsset);

        string memory calculatedName = string(
            abi.encodePacked("Vader USDV /", _foreignAsset.symbol(), " LP")
        );
        _name = calculatedName;
    }

    /* ========== VIEWS ========== */

    /*
     * @dev Returns the realised amount of native and foreign assets, and the last timestamp
     * at which the cumulative prices for native and foreign assets were updated.
     **/
    function getReserves()
        public
        view
        returns (
            uint112 reserveNative,
            uint112 reserveForeign,
            uint32 blockTimestampLast
        )
    {
        reserveNative = _reserveNative;
        reserveForeign = _reserveForeign;
        blockTimestampLast = _blockTimestampLast;
    }

    // Returns the name of the contract.
    function name() public view override returns (string memory) {
        return _name;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /*
     * @dev Allows depositing of liquidity to the pool by accepting native and foreign assets
     * and mints an NFT to the {to} address which records the amounts of the native and foreign
     * assets deposited and the liquidity units minted against it in {positions} mapping.
     *
     * Updates the total supply of liquidity units by adding currently minted liquidity units
     * to {totalSupply}.
     *
     * Updates the cumulative prices of native and foreign assets after minting the appropriate
     * liquidity units.
     *
     * Requirements:
     * - Amounts of native and foreign must be sent to the pool prior to calling `mint` such that
     *   balance of pool for both assets must be greater than their corresponding reserves.
     * - The amount of {liquidity} to be minted must be greater than 0.
     **/
    function mint(address to)
        external
        override
        nonReentrant
        returns (uint256 liquidity)
    {
        (uint112 reserveNative, uint112 reserveForeign, ) = getReserves(); // gas savings
        uint256 balanceNative = nativeAsset.balanceOf(address(this));
        uint256 balanceForeign = foreignAsset.balanceOf(address(this));
        uint256 nativeDeposit = balanceNative - reserveNative;
        uint256 foreignDeposit = balanceForeign - reserveForeign;

        uint256 totalLiquidityUnits = totalSupply;
        if (totalLiquidityUnits == 0)
            liquidity = nativeDeposit; // TODO: Contact ThorChain on proper approach
        else
            liquidity = VaderMath.calculateLiquidityUnits(
                nativeDeposit,
                reserveNative,
                foreignDeposit,
                reserveForeign,
                totalLiquidityUnits
            );

        require(
            liquidity > 0,
            "BasePool::mint: Insufficient Liquidity Provided"
        );

        uint256 id = positionId++;

        totalSupply += liquidity;
        _mint(to, id);

        positions[id] = Position(
            block.timestamp,
            liquidity,
            nativeDeposit,
            foreignDeposit
        );

        _update(balanceNative, balanceForeign, reserveNative, reserveForeign);

        emit Mint(msg.sender, to, nativeDeposit, foreignDeposit);
        emit PositionOpened(msg.sender, id, liquidity);
    }

    /*
     * @dev Allows redeeming of liquidity units by burning the NFT associated with the liquidity
     * position.
     *
     * Computes the amounts of native and foreign assets depending upon current reserves of assets and
     * the liquidity associated with the position, and transfers them to the {to} address.
     *
     * Burns the redeemed NFT token and decreases {totalSupply} by the {liquidity}
     * associated with that NFT token.
     *
     * Updates the cumulative prices for native and foreign assets after transferring the assets
     * to the {to} address.
     *
     * Requirements:
     * - The NFT token being redeemed must be transferred to the pool prior to calling `_burn`.
     * - The amount of native and foreign assets computed for transfer to {to} address must be greater
     *   than 0.
     **/
    function _burn(uint256 id, address to)
        internal
        nonReentrant
        returns (uint256 amountNative, uint256 amountForeign)
    {
        require(
            ownerOf(id) == address(this),
            "BasePool::burn: Incorrect Ownership"
        );

        (uint112 reserveNative, uint112 reserveForeign, ) = getReserves(); // gas savings
        IERC20 _nativeAsset = nativeAsset; // gas savings
        IERC20 _foreignAsset = foreignAsset; // gas savings
        uint256 nativeBalance = IERC20(_nativeAsset).balanceOf(address(this));
        uint256 foreignBalance = IERC20(_foreignAsset).balanceOf(address(this));

        uint256 liquidity = positions[id].liquidity;

        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amountNative = (liquidity * nativeBalance) / _totalSupply; // using balances ensures pro-rata distribution
        amountForeign = (liquidity * foreignBalance) / _totalSupply; // using balances ensures pro-rata distribution

        require(
            amountNative > 0 && amountForeign > 0,
            "BasePool::burn: Insufficient Liquidity Burned"
        );

        totalSupply -= liquidity;
        _burn(id);

        _nativeAsset.safeTransfer(to, amountNative);
        _foreignAsset.safeTransfer(to, amountForeign);

        nativeBalance = _nativeAsset.balanceOf(address(this));
        foreignBalance = _foreignAsset.balanceOf(address(this));

        _update(nativeBalance, foreignBalance, reserveNative, reserveForeign);

        emit Burn(msg.sender, amountNative, amountForeign, to);
    }

    /*
     * @dev  Allows swapping between native and foreign assets. It receives the source asset
     * and computes the destination asset and transfers it to the {to} address.
     *
     * Internally calls {swap} function.
     **/
    function swap(
        uint256 nativeAmountIn,
        uint256 foreignAmountIn,
        address to,
        bytes calldata
    ) external override returns (uint256) {
        return swap(nativeAmountIn, foreignAmountIn, to);
    }

    /*
     * @dev Allows swapping between native and foreign assets. It receives the source asset
     * and computes the destination asset and transfers it to the {to} address.
     *
     * Updates the cumulative prices for native and foreign assets after performing swap.
     *
     * Returns the amount of destination tokens resulting from the swap.
     *
     * Requirements:
     * - Param {nativeAmountIn} must be zero and {foreignAmountIn} must be non-zero
     *   if the destination asset in swap is native asset.
     * - Param {foreignAmountIn} must be zero and {nativeAmountIn} must be non zero
     *   if the destination asset in swap is foreign asset.
     * - Param {to} cannot be the addresses of native or foreign assets.
     * - The source asset amount in the swap must be transferred to the pool prior to calling `swap`.
     * - The source asset amount in the swap cannot exceed the source asset's reserve.
     * - The destination asset's amount in the swap must be greater than 0 and not exceed destination
     *   asset's reserve.
     **/
    function swap(
        uint256 nativeAmountIn,
        uint256 foreignAmountIn,
        address to
    ) public override nonReentrant validateGas returns (uint256) {
        require(
            (nativeAmountIn > 0 && foreignAmountIn == 0) ||
                (nativeAmountIn == 0 && foreignAmountIn > 0),
            "BasePool::swap: Only One-Sided Swaps Supported"
        );
        (uint112 nativeReserve, uint112 foreignReserve, ) = getReserves(); // gas savings

        uint256 nativeBalance;
        uint256 foreignBalance;
        uint256 nativeAmountOut;
        uint256 foreignAmountOut;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            IERC20 _nativeAsset = nativeAsset;
            IERC20 _foreignAsset = foreignAsset;
            nativeBalance = _nativeAsset.balanceOf(address(this));
            foreignBalance = _foreignAsset.balanceOf(address(this));

            require(
                to != address(_nativeAsset) && to != address(_foreignAsset),
                "BasePool::swap: Invalid Receiver"
            );

            if (foreignAmountIn > 0) {
                require(
                    foreignAmountIn <= foreignBalance - foreignReserve,
                    "BasePool::swap: Insufficient Tokens Provided"
                );
                require(
                    foreignAmountIn <= foreignReserve,
                    "BasePool::swap: Unfavourable Trade"
                );

                nativeAmountOut = VaderMath.calculateSwap(
                    foreignAmountIn,
                    foreignReserve,
                    nativeReserve
                );

                require(
                    nativeAmountOut > 0 && nativeAmountOut <= nativeReserve,
                    "BasePool::swap: Swap Impossible"
                );

                _nativeAsset.safeTransfer(to, nativeAmountOut); // optimistically transfer tokens
            } else {
                require(
                    nativeAmountIn <= nativeBalance - nativeReserve,
                    "BasePool::swap: Insufficient Tokens Provided"
                );
                require(
                    nativeAmountIn <= nativeReserve,
                    "BasePool::swap: Unfavourable Trade"
                );

                foreignAmountOut = VaderMath.calculateSwap(
                    nativeAmountIn,
                    nativeReserve,
                    foreignReserve
                );

                require(
                    foreignAmountOut > 0 && foreignAmountOut <= foreignReserve,
                    "BasePool::swap: Swap Impossible"
                );

                _foreignAsset.safeTransfer(to, foreignAmountOut); // optimistically transfer tokens
            }

            nativeBalance = _nativeAsset.balanceOf(address(this));
            foreignBalance = _foreignAsset.balanceOf(address(this));
        }

        _update(nativeBalance, foreignBalance, nativeReserve, foreignReserve);

        emit Swap(
            msg.sender,
            nativeAmountIn,
            foreignAmountIn,
            nativeAmountOut,
            foreignAmountOut,
            to
        );

        return nativeAmountOut > 0 ? nativeAmountOut : foreignAmountOut;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /* ========== INTERNAL FUNCTIONS ========== */

    /*
     * @dev Internally called to update the cumulative prices for native and foreign assets depending
     * upon the last reserves and updates the reserves for both of the assets corresponding to their
     * current balances along with the {_blockTimestampLast}.
     *
     * Requirements:
     * - Params {balanceNative} and {balanceForeign} must not overflow type `uint112`.
     *
     **/
    function _update(
        uint256 balanceNative,
        uint256 balanceForeign,
        uint112 reserveNative,
        uint112 reserveForeign
    ) internal {
        require(
            balanceNative <= type(uint112).max &&
                balanceForeign <= type(uint112).max,
            "BasePool::_update: Balance Overflow"
        );
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        unchecked {
            uint32 timeElapsed = blockTimestamp - _blockTimestampLast; // overflow is desired
            if (timeElapsed > 0 && reserveNative != 0 && reserveForeign != 0) {
                // * never overflows, and + overflow is desired
                priceNativeCumulativeLast +=
                    uint256(
                        UQ112x112.encode(reserveForeign).uqdiv(reserveNative)
                    ) *
                    timeElapsed;
                priceForeignCumulativeLast +=
                    uint256(
                        UQ112x112.encode(reserveNative).uqdiv(reserveForeign)
                    ) *
                    timeElapsed;
            }
        }
        _reserveNative = uint112(balanceNative);
        _reserveForeign = uint112(balanceForeign);
        _blockTimestampLast = blockTimestamp;
        emit Sync(balanceNative, balanceForeign);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /* ========== MODIFIERS ========== */
}

contract StakingRewards is
    IStakingRewards,
    RewardsDistributionRecipient,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable rewardsToken;
    IERC20 public immutable stakingToken;
    uint public periodFinish;
    uint public rewardRate;
    uint public rewardsDuration = 7 days;
    uint public lastUpdateTime;
    uint public rewardPerTokenStored;

    mapping(address => uint) public userRewardPerTokenPaid;
    mapping(address => uint) public rewards;

    uint private _totalSupply;
    mapping(address => uint) private _balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken
    ) Owned(_owner) {
        require(_rewardsDistribution != address(0), "reward dist = zero address");
        require(_rewardsToken != address(0), "reward token = zero address");
        require(_stakingToken != address(0), "staking token = zero address");

        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsDistribution = _rewardsDistribution;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) /
            _totalSupply;
    }

    function earned(address account) public view returns (uint) {
        return
            _balances[account] *
            ((rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18) +
            rewards[account];
    }

    function getRewardForDuration() external view returns (uint) {
        return rewardRate * rewardsDuration;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint amount)
        external
        nonReentrant
        notPaused
        updateReward(msg.sender)
    {
        require(amount > 0, "Cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint reward)
        external
        override
        onlyRewardsDistribution
        updateReward(address(0))
    {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint remaining = periodFinish - block.timestamp;
            uint leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance / rewardsDuration, "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint tokenAmount) external onlyOwner {
        require(
            tokenAddress != address(stakingToken),
            "Cannot withdraw the staking token"
        );
        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint _rewardsDuration) external onlyOwner {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(_rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint reward);
    event Staked(address indexed user, uint amount);
    event Withdrawn(address indexed user, uint amount);
    event RewardPaid(address indexed user, uint reward);
    event RewardsDurationUpdated(uint newDuration);
    event Recovered(address token, uint amount);
}

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using UQ112x112 for uint224;

    uint256 public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR =
        bytes4(keccak256(bytes("transfer(address,uint256)")));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint256 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(SELECTOR, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "UniswapV2: TRANSFER_FAILED"
        );
    }

    constructor() {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "UniswapV2: FORBIDDEN"); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        require(
            balance0 <= type(uint112).max && balance1 <= type(uint112).max,
            "UniswapV2: OVERFLOW"
        );
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast +=
                uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) *
                timeElapsed;
            price1CumulativeLast +=
                uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) *
                timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1)
        private
        returns (bool feeOn)
    {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply * (rootK - rootKLast);
                    uint256 denominator = (rootK * 5) + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(
                (amount0 * (_totalSupply)) / _reserve0,
                (amount1 * (_totalSupply)) / _reserve1
            );
        }
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = (liquidity * balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = (liquidity * balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(
            amount0 > 0 && amount1 > 0,
            "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED"
        );
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1; // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external lock {
        require(
            amount0Out > 0 || amount1Out > 0,
            "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            "UniswapV2: INSUFFICIENT_LIQUIDITY"
        );

        uint256 balance0;
        uint256 balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0)
                IUniswapV2Callee(to).uniswapV2Call(
                    msg.sender,
                    amount0Out,
                    amount1Out,
                    data
                );
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out)
            : 0;
        require(
            amount0In > 0 || amount1In > 0,
            "UniswapV2: INSUFFICIENT_INPUT_AMOUNT"
        );
        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
            uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);
            require(
                balance0Adjusted * balance1Adjusted >=
                    uint256(_reserve0) * _reserve1 * 1000**2,
                "UniswapV2: K"
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(
            _token0,
            to,
            IERC20(_token0).balanceOf(address(this)) - reserve0
        );
        _safeTransfer(
            _token1,
            to,
            IERC20(_token1).balanceOf(address(this)) - reserve1
        );
    }

    // force reserves to match balances
    function sync() external lock {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }
}

library UniswapV2Library {
    using SafeMath for uint256;

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, "UniswapV2Library: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "UniswapV2Library: ZERO_ADDRESS");
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        unchecked {
            pair = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                factory,
                                keccak256(abi.encodePacked(token0, token1)),
                                hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f" // init code hash
                            )
                        )
                    )
                )
            );
        }
    }

    // fetches and sorts the reserves for a pair
    function getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(
            pairFor(factory, tokenA, tokenB)
        ).getReserves();
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        require(amountA > 0, "UniswapV2Library: INSUFFICIENT_AMOUNT");
        require(
            reserveA > 0 && reserveB > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn.mul(997);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn.mul(amountOut).mul(1000);
        uint256 denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(
        address factory,
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(
                factory,
                path[i],
                path[i + 1]
            );
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(
        address factory,
        uint256 amountOut,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(
                factory,
                path[i - 1],
                path[i]
            );
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}

library UniswapV2OracleLibrary {
    using FixedPoint for *;

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(address pair)
        internal
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        )
    {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        ) = IUniswapV2Pair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative +=
                uint256(FixedPoint.fraction(reserve1, reserve0)._x) *
                timeElapsed;
            // counterfactual
            price1Cumulative +=
                uint256(FixedPoint.fraction(reserve0, reserve1)._x) *
                timeElapsed;
        }
    }
}

interface IVaderPoolFactory {
    /* ========== STRUCTS ========== */

    /* ========== FUNCTIONS ========== */

    function createPool(address tokenA, address tokenB)
        external
        returns (IVaderPool);

    function getPool(address tokenA, address tokenB)
        external
        view
        returns (IVaderPool);

    function nativeAsset() external view returns (address);

    /* ========== EVENTS ========== */

    event PoolCreated(
        address token0,
        address token1,
        IVaderPool pool,
        uint256 index
    );
}

/*
 @dev Implementation of {VaderRouterV2} contract.
 *
 * The contract VaderRouter inherits from {Ownable} and {ProtocolConstants} contracts.
 *
 * It allows adding of liquidity to Vader pairs.
 *
 * Allows removing of liquidity by the users and claiming the underlying assets from
 * the Vader pairs/pools.
 *
 * Allows swapping between native and foreign assets within a single Vader pair.
 *
 * Allows swapping of foreign assets across two different Vader pairs.
 **/
contract VaderRouterV2 is IVaderRouterV2, ProtocolConstants, Ownable {
    /* ========== LIBRARIES ========== */

    // Used for safe token transfers
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // Address of the Vader pool contract.
    IVaderPoolV2 public immutable pool;

    // Address of native asset (USDV or Vader).
    IERC20 public immutable nativeAsset;

    // Address of reserve contract.
    IVaderReserve public reserve;

    /* ========== CONSTRUCTOR ========== */

    /*
     * @dev Initialises contract by setting pool and native asset addresses.
     *
     * Native assets address is taken from param {_pool} and native asset's address
     * is retrieved from {VaderPoolV2} contract.
     **/
    constructor(IVaderPoolV2 _pool) {
        require(
            _pool != IVaderPoolV2(_ZERO_ADDRESS),
            "VaderRouterV2::constructor: Incorrect Arguments"
        );

        pool = _pool;
        nativeAsset = pool.nativeAsset();
    }

    /* ========== VIEWS ========== */

    /* ========== MUTATIVE FUNCTIONS ========== */

    /*
     * @dev Allows adding of liquidity to the Vader pool.
     *
     * Internally calls {addLiquidity} function.
     *
     * Returns the amount of liquidity minted.
     **/
    // NOTE: For Uniswap V2 compliancy, necessary due to stack too deep
    function addLiquidity(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256, // amountAMin = unused
        uint256, // amountBMin = unused
        address to,
        uint256 deadline
    ) external override returns (uint256 liquidity) {
        return
            addLiquidity(
                tokenA,
                tokenB,
                amountADesired,
                amountBDesired,
                to,
                deadline
            );
    }

    /*
     * @dev Allows adding of liquidity to the Vader pool.
     *
     * Calls `mint` function on the {BasePoolV2} contract.
     *
     * Pair is determined based {tokenA} and {tokenB} where one of them represents
     * native asset and the other one represents foreign asset.
     *
     * Returns the amount of liquidity units minted against a pair.
     *
     * Requirements:
     * - The current timestamp has not exceeded the param {deadline}.
     * - Amongst {tokenA} and {tokenB}, one should be the native asset and the other
     *   one must be the foreign asset.
     * - The foreign asset among {tokenA} and {tokenB} must be a supported token.
     **/
    function addLiquidity(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        address to,
        uint256 deadline
    ) public override ensure(deadline) returns (uint256 liquidity) {
        IERC20 foreignAsset;
        uint256 nativeDeposit;
        uint256 foreignDeposit;

        if (tokenA == nativeAsset) {
            require(
                pool.supported(tokenB),
                "VaderRouterV2::addLiquidity: Unsupported Assets Specified"
            );
            foreignAsset = tokenB;
            foreignDeposit = amountBDesired;
            nativeDeposit = amountADesired;
        } else {
            require(
                tokenB == nativeAsset && pool.supported(tokenA),
                "VaderRouterV2::addLiquidity: Unsupported Assets Specified"
            );
            foreignAsset = tokenA;
            foreignDeposit = amountADesired;
            nativeDeposit = amountBDesired;
        }

        liquidity = pool.mint(
            foreignAsset,
            nativeDeposit,
            foreignDeposit,
            msg.sender,
            to
        );
    }

    /*
     * @dev Allows removing of liquidity by {msg.sender} and transfers the
     * underlying assets to {to} address.
     *
     * The liquidity is removed from a pair represented by {tokenA} and {tokenB}.
     *
     * Transfers the NFT with Id {id} representing user's position, to the pool address,
     * so the pool is able to burn it in the `burn` function call.
     *
     * Calls the `burn` function on the pool contract.
     *
     * Calls the `reimburseImpermanentLoss` on reserve contract to cover impermanent loss
     * for the liquidity being removed.
     *
     * Requirements:
     * - The underlying assets amounts of {amountA} and {amountB} must
     *   be greater than or equal to {amountAMin} and {amountBMin}, respectively.
     * - The current timestamp has not exceeded the param {deadline}.
     * - Either of {tokenA} or {tokenB} should be a native asset and the other one
     *   must be the foreign asset associated with the NFT representing liquidity.
     **/
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 id,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        public
        override
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        IERC20 _foreignAsset = pool.positionForeignAsset(id);
        IERC20 _nativeAsset = nativeAsset;

        bool isNativeA = _nativeAsset == IERC20(tokenA);

        if (isNativeA) {
            require(
                IERC20(tokenB) == _foreignAsset,
                "VaderRouterV2::removeLiquidity: Incorrect Addresses Specified"
            );
        } else {
            require(
                IERC20(tokenA) == _foreignAsset &&
                    IERC20(tokenB) == _nativeAsset,
                "VaderRouterV2::removeLiquidity: Incorrect Addresses Specified"
            );
        }

        pool.transferFrom(msg.sender, address(pool), id);

        (
            uint256 amountNative,
            uint256 amountForeign,
            uint256 coveredLoss
        ) = pool.burn(id, to);

        (amountA, amountB) = isNativeA
            ? (amountNative, amountForeign)
            : (amountForeign, amountNative);

        require(
            amountA >= amountAMin,
            "VaderRouterV2: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountB >= amountBMin,
            "VaderRouterV2: INSUFFICIENT_B_AMOUNT"
        );

        reserve.reimburseImpermanentLoss(msg.sender, coveredLoss);
    }

    /*
     * @dev Allows swapping of exact source token amount to destination
     * token amount.
     *
     * Internally calls {_swap} function.
     *
     * Requirements:
     * - The destination amount {amountOut} must greater than or equal to param {amountOutMin}.
     * - The current timestamp has not exceeded the param {deadline}.
     **/
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        IERC20[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) returns (uint256 amountOut) {
        amountOut = _swap(amountIn, path, to);

        require(
            amountOut >= amountOutMin,
            "VaderRouterV2::swapExactTokensForTokens: Insufficient Trade Output"
        );
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /*
    * @dev Sets the reserve address and renounces contract's ownership.
     *
     * Requirements:
     * - Only existing owner can call this function.
     * - Param {_reserve} cannot be a zero address.
     **/
    function initialize(IVaderReserve _reserve) external onlyOwner {
        require(
            _reserve != IVaderReserve(_ZERO_ADDRESS),
            "VaderRouterV2::initialize: Incorrect Reserve Specified"
        );

        reserve = _reserve;

        // renounceOwnership();
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== PRIVATE FUNCTIONS ========== */

    /*
     * @dev Allows swapping of assets from within a single Vader pool pair or
     * across two different Vader pairs.
     *
     * In case of a single Vader pair, the native asset can be swapped for foreign
     * asset and vice versa.
     *
     * In case of two Vader pairs, the foreign asset is swapped for native asset from
     * the first Vader pool and the native asset retrieved from the first Vader pair is swapped
     * for foreign asset from the second Vader pair.
     *
     * Requirements:
     * - Param {path} length can be either 2 or 3.
     * - If the {path} length is 3 the index 0 and 1 must contain foreign assets' addresses
     *   and index 1 must contain native asset's address.
     * - If the {path} length is 2 then either of indexes must contain foreign asset's address
     *   and the other one must contain native asset's address.
     **/
    function _swap(
        uint256 amountIn,
        IERC20[] calldata path,
        address to
    ) private returns (uint256 amountOut) {
        if (path.length == 3) {
            require(
                path[0] != path[1] &&
                    path[1] == pool.nativeAsset() &&
                    path[2] != path[1],
                "VaderRouterV2::_swap: Incorrect Path"
            );

            path[0].safeTransferFrom(msg.sender, address(pool), amountIn);

            return pool.doubleSwap(path[0], path[2], amountIn, to);
        } else {
            require(
                path.length == 2,
                "VaderRouterV2::_swap: Incorrect Path Length"
            );
            IERC20 _nativeAsset = nativeAsset;
            require(path[0] != path[1], "VaderRouterV2::_swap: Incorrect Path");

            path[0].safeTransferFrom(msg.sender, address(pool), amountIn);
            if (path[0] == _nativeAsset) {
                return pool.swap(path[1], amountIn, 0, to);
            } else {
                require(
                    path[1] == _nativeAsset,
                    "VaderRouterV2::_swap: Incorrect Path"
                );
                return pool.swap(path[0], 0, amountIn, to);
            }
        }
    }

    /* ========== MODIFIERS ========== */

    // Guard ensuring that the current timestamp has not exceeded the param {deadline}.
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "VaderRouterV2::ensure: Expired");
        _;
    }
}

interface IVaderPoolFactoryV2 {
    /* ========== STRUCTS ========== */

    /* ========== FUNCTIONS ========== */

    function createPool(address tokenA, address tokenB)
        external
        returns (IVaderPoolV2);

    function getPool(address tokenA, address tokenB)
        external
        returns (IVaderPoolV2);

    function nativeAsset() external view returns (address);

    /* ========== EVENTS ========== */

    event PoolCreated(
        address token0,
        address token1,
        IVaderPoolV2 pool,
        uint256 totalPools
    );
}

contract SynthFactory is ISynthFactory, ProtocolConstants, Ownable {
    mapping(IERC20 => ISynth) public override synths;

    constructor(address _pool) {
        require(
            _pool != _ZERO_ADDRESS,
            "SynthFactory::constructor: Misconfiguration"
        );
        // transferOwnership(_pool);
    }

    function createSynth(IERC20Extended token)
        external
        override
        onlyOwner
        returns (ISynth)
    {
        require(
            synths[IERC20(token)] == ISynth(_ZERO_ADDRESS),
            "SynthFactory::createSynth: Already Created"
        );

        Synth synth = new Synth(token);

        // synth.transferOwnership(owner());

        synths[IERC20(token)] = synth;

        return synth;
    }
}

contract LPToken is ILPToken, ProtocolConstants, ERC20, Ownable {
    IERC20Extended public immutable foreignAsset;
    IVaderPoolV2 public immutable pool;

    /* ========== CONSTRUCTOR ========== */

    constructor(IERC20Extended _foreignAsset, IVaderPoolV2 _pool)
        ERC20(_calculateName(_foreignAsset), _calculateSymbol(_foreignAsset))
    {
        foreignAsset = _foreignAsset;
        pool = _pool;
        // transferOwnership(address(_pool));
    }

    /* ========== VIEWS ========== */

    function totalSupply() public view override returns (uint256) {
        return pool.pairSupply(foreignAsset);
    }

    function balanceOf(address user) public view override returns (uint256) {
        if (user == address(pool)) return totalSupply() - ERC20.totalSupply();
        else return ERC20.balanceOf(user);
    }

    function _calculateName(IERC20Extended token)
        internal
        view
        returns (string memory)
    {
        return _combine(token.name(), " - USDV LP");
    }

    function _calculateSymbol(IERC20Extended token)
        internal
        view
        returns (string memory)
    {
        return _combine("V(", token.symbol(), "|USDV)");
    }

    function _combine(string memory a, string memory b)
        internal
        pure
        returns (string memory)
    {
        return _combine(a, b, "");
    }

    function _combine(
        string memory a,
        string memory b,
        string memory c
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b, c));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyOwner {
        _burn(msg.sender, amount);
    }
}

/*
 * @dev Implementation of {VaderPoolV2} contract.
 *
 * The contract VaderPool inherits from {BasePoolV2} contract and implements
 * queue system.
 *
 * Extends on the liquidity redeeming function by introducing the `burn` function
 * that internally calls the namesake on `BasePoolV2` contract and computes the
 * loss covered by the position being redeemed and returns it along with amounts
 * of native and foreign assets sent.
 **/
contract VaderPoolV2 is IVaderPoolV2, BasePoolV2, Ownable {
    /* ========== LIBRARIES ========== */

    // Used for safe token transfers
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // The LP wrapper contract
    ILPWrapper public wrapper;

    // The Synth Factory
    ISynthFactory public synthFactory;

    // Denotes whether the queue system is active
    bool public queueActive;

    /* ========== CONSTRUCTOR ========== */

    /*
     * @dev Initialised the contract state by passing the native asset's address
     * to the inherited {BasePoolV2} contract's constructor and setting queue status
     * to the {queueActive} state variable.
     **/
    constructor(bool _queueActive, IERC20 _nativeAsset)
        BasePoolV2(_nativeAsset)
    {
        queueActive = _queueActive;
    }

    /* ========== VIEWS ========== */

    /*
     * @dev Returns cumulative prices and the timestamp the were last updated
     * for both native and foreign assets against the pair specified by
     * parameter {foreignAsset}.
     **/
    function cumulativePrices(IERC20 foreignAsset)
        public
        view
        returns (
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint32 blockTimestampLast
        )
    {
        PriceCumulative memory priceCumulative = pairInfo[foreignAsset]
            .priceCumulative;
        price0CumulativeLast = priceCumulative.nativeLast;
        price1CumulativeLast = priceCumulative.foreignLast;
        blockTimestampLast = pairInfo[foreignAsset].blockTimestampLast;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /*
     * @dev Initializes contract's state with LP wrapper, synth factory
     * and router addresses.
     *
     * Requirements:
     * - None of the parameters are zero addresses.
     * - The parameters are not already set.
     * - Only callable by contract owner.
     **/
    function initialize(
        ILPWrapper _wrapper,
        ISynthFactory _synthFactory,
        address _router
    ) external onlyOwner {
        require(
            wrapper == ILPWrapper(_ZERO_ADDRESS),
            "VaderPoolV2::initialize: Already initialized"
        );
        require(
            _wrapper != ILPWrapper(_ZERO_ADDRESS),
            "VaderPoolV2::initialize: Incorrect Wrapper Specified"
        );
        require(
            _synthFactory != ISynthFactory(_ZERO_ADDRESS),
            "VaderPoolV2::initialize: Incorrect SynthFactory Specified"
        );
        require(
            _router != _ZERO_ADDRESS,
            "VaderPoolV2::initialize: Incorrect Router Specified"
        );
        wrapper = _wrapper;
        synthFactory = _synthFactory;
        router = _router;
    }

    /*
     * @dev Allows minting of synthetic assets corresponding to the {foreignAsset} based
     * on the native asset amount deposited and returns the minted synth asset amount.
     *
     * Creates the synthetic asset against {foreignAsset} if it does not already exist.
     *
     * Updates the cumulative prices for native and foreign assets.
     *
     * Requirements:
     * - {foreignAsset} must be a supported token.
     **/
    function mintSynth(
        IERC20 foreignAsset,
        uint256 nativeDeposit,
        address from,
        address to
    )
        external
        override
        nonReentrant
        supportedToken(foreignAsset)
        returns (uint256 amountSynth)
    {
        nativeAsset.safeTransferFrom(from, address(this), nativeDeposit);

        ISynth synth = synthFactory.synths(foreignAsset);

        if (synth == ISynth(_ZERO_ADDRESS))
            synth = synthFactory.createSynth(
                IERC20Extended(address(foreignAsset))
            );

        (uint112 reserveNative, uint112 reserveForeign, ) = getReserves(
            foreignAsset
        ); // gas savings

        amountSynth = VaderMath.calculateSwap(
            nativeDeposit,
            reserveNative,
            reserveForeign
        );

        // TODO: Clarify
        _update(
            foreignAsset,
            reserveNative + nativeDeposit,
            reserveForeign,
            reserveNative,
            reserveForeign
        );

        synth.mint(to, amountSynth);
    }

    /*
     * @dev Allows burning of synthetic assets corresponding to the {foreignAsset}
     * and returns the redeemed amount of native asset.
     *
     * Updates the cumulative prices for native and foreign assets.
     *
     * Requirements:
     * - {foreignAsset} must have a valid synthetic asset against it.
     * - {synthAmount} must be greater than zero.
     **/
    function burnSynth(
        IERC20 foreignAsset,
        uint256 synthAmount,
        address to
    ) external override nonReentrant returns (uint256 amountNative) {
        ISynth synth = synthFactory.synths(foreignAsset);

        require(
            synth != ISynth(_ZERO_ADDRESS),
            "VaderPoolV2::burnSynth: Inexistent Synth"
        );

        require(
            synthAmount > 0,
            "VaderPoolV2::burnSynth: Insufficient Synth Amount"
        );

        IERC20(synth).safeTransferFrom(msg.sender, address(this), synthAmount);
        synth.burn(synthAmount);

        (uint112 reserveNative, uint112 reserveForeign, ) = getReserves(
            foreignAsset
        ); // gas savings

        amountNative = VaderMath.calculateSwap(
            synthAmount,
            reserveForeign,
            reserveNative
        );

        // TODO: Clarify
        _update(
            foreignAsset,
            reserveNative - amountNative,
            reserveForeign,
            reserveNative,
            reserveForeign
        );

        nativeAsset.safeTransfer(to, amountNative);
    }

    /*
     * @dev Allows burning of NFT represented by param {id} for liquidity redeeming.
     *
     * Deletes the position in {positions} mapping against the burned NFT token.
     *
     * Internally calls `_burn` function on {BasePoolV2} contract.
     *
     * Calculates the impermanent loss incurred by the position.
     *
     * Returns the amounts for native and foreign assets sent to the {to} address
     * along with the covered loss.
     *
     * Requirements:
     * - Can only be called by the Router.
     **/
    // NOTE: IL is only covered via router!
    function burn(uint256 id, address to)
        external
        override
        onlyRouter
        returns (
            uint256 amountNative,
            uint256 amountForeign,
            uint256 coveredLoss
        )
    {
        (amountNative, amountForeign) = _burn(id, to);

        Position storage position = positions[id];

        uint256 creation = position.creation;
        uint256 originalNative = position.originalNative;
        uint256 originalForeign = position.originalForeign;

        delete positions[id];

        // NOTE: Validate it behaves as expected for non-18 decimal tokens
        uint256 loss = VaderMath.calculateLoss(
            originalNative,
            originalForeign,
            amountNative,
            amountForeign
        );

        // TODO: Original Implementation Applied 100 Days
        coveredLoss =
            (loss * _min(block.timestamp - creation, _ONE_YEAR)) /
            _ONE_YEAR;
    }

    /*
     * @dev Allows minting of liquidity in fungible tokens. The fungible token
     * is a wrapped LP token against a particular pair. The liquidity issued is also
     * tracked within this contract along with liquidity issued against non-fungible
     * token.
     *
     * Updates the cumulative prices for native and foreign assets.
     *
     * Calls 'mint' on the LP wrapper token contract.
     *
     * Requirements:
     * - LP wrapper token must exist against {foreignAsset}.
     **/
    function mintFungible(
        IERC20 foreignAsset,
        uint256 nativeDeposit,
        uint256 foreignDeposit,
        address from,
        address to
    ) external override nonReentrant returns (uint256 liquidity) {
        IERC20Extended lp = wrapper.tokens(foreignAsset);

        require(
            lp != IERC20Extended(_ZERO_ADDRESS),
            "VaderPoolV2::mintFungible: Unsupported Token"
        );

        (uint112 reserveNative, uint112 reserveForeign, ) = getReserves(
            foreignAsset
        ); // gas savings

        nativeAsset.safeTransferFrom(from, address(this), nativeDeposit);
        foreignAsset.safeTransferFrom(from, address(this), foreignDeposit);

        PairInfo storage pair = pairInfo[foreignAsset];
        uint256 totalLiquidityUnits = pair.totalSupply;
        if (totalLiquidityUnits == 0) liquidity = nativeDeposit;
        else
            liquidity = VaderMath.calculateLiquidityUnits(
                nativeDeposit,
                reserveNative,
                foreignDeposit,
                reserveForeign,
                totalLiquidityUnits
            );

        require(
            liquidity > 0,
            "VaderPoolV2::mintFungible: Insufficient Liquidity Provided"
        );

        pair.totalSupply = totalLiquidityUnits + liquidity;

        _update(
            foreignAsset,
            reserveNative + nativeDeposit,
            reserveForeign + foreignDeposit,
            reserveNative,
            reserveForeign
        );

        lp.mint(to, liquidity);

        emit Mint(from, to, nativeDeposit, foreignDeposit);
    }

    /*
     * @dev Allows burning of liquidity issued in fungible tokens.
     *
     * Updates the cumulative prices for native and foreign assets.
     *
     * Calls 'burn' on the LP wrapper token contract.
     *
     * Requirements:
     * - LP wrapper token must exist against {foreignAsset}.
     * - {amountNative} and {amountForeign} redeemed, both must be greater than zero.,
     **/
    function burnFungible(
        IERC20 foreignAsset,
        uint256 liquidity,
        address to
    )
        external
        override
        nonReentrant
        returns (uint256 amountNative, uint256 amountForeign)
    {
        IERC20Extended lp = wrapper.tokens(foreignAsset);

        require(
            lp != IERC20Extended(_ZERO_ADDRESS),
            "VaderPoolV2::burnFungible: Unsupported Token"
        );

        IERC20(lp).safeTransferFrom(msg.sender, address(this), liquidity);
        lp.burn(liquidity);

        (uint112 reserveNative, uint112 reserveForeign, ) = getReserves(
            foreignAsset
        ); // gas savings

        PairInfo storage pair = pairInfo[foreignAsset];
        uint256 _totalSupply = pair.totalSupply;
        amountNative = (liquidity * reserveNative) / _totalSupply;
        amountForeign = (liquidity * reserveForeign) / _totalSupply;

        require(
            amountNative > 0 && amountForeign > 0,
            "VaderPoolV2::burnFungible: Insufficient Liquidity Burned"
        );

        pair.totalSupply = _totalSupply - liquidity;

        nativeAsset.safeTransfer(to, amountNative);
        foreignAsset.safeTransfer(to, amountForeign);

        _update(
            foreignAsset,
            reserveNative - amountNative,
            reserveForeign - amountForeign,
            reserveNative,
            reserveForeign
        );

        emit Burn(msg.sender, amountNative, amountForeign, to);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // TODO: Investigate Necessity
    function toggleQueue() external override onlyOwner {
        bool _queueActive = !queueActive;
        queueActive = _queueActive;
        emit QueueActive(_queueActive);
    }

    /*
     * @dev Sets the supported state of the token represented by param {foreignAsset}.
     *
     * Requirements:
     * - The param {foreignAsset} is not already a supported token.
     **/
    function setTokenSupport(IERC20 foreignAsset, bool support)
        external
        override
        onlyOwner
    {
        require(
            supported[foreignAsset] != support,
            "VaderPoolV2::supportToken: Already At Desired State"
        );
        supported[foreignAsset] = support;
    }

    /*
     * @dev Sets the supported state of the token represented by param {foreignAsset}.
     *
     * Requirements:
     * - The param {foreignAsset} is not already a supported token.
     **/
    function setFungibleTokenSupport(IERC20 foreignAsset)
        external
        override
        onlyOwner
    {
        wrapper.createWrapper(foreignAsset);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== PRIVATE FUNCTIONS ========== */

    /**
     * @dev Calculates the minimum of the two values
     */
    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/*
 * @dev Implementation of {VaderPool} contract.
 *
 * The contract VaderPool inherits from {BasePool} contract and implements
 * queue system.
 *
 * Extends on the liquidity redeeming function by introducing the `burn` function
 * that internally calls the namesake on `BasePool` contract and computes the
 * loss covered by the position being redeemed and returns it along with amounts
 * of native and foreign assets sent.
 **/
contract VaderPool is IVaderPool, BasePool {
    /* ========== STATE VARIABLES ========== */

    // Denotes whether the queue system is active
    bool public queueActive;

    /* ========== CONSTRUCTOR ========== */

    /*
     * @dev Initializes contract's state by passing addresses of
     * native and foreign assets to {BasePool} contract and setting
     * active status of queue.
     **/
    constructor(
        bool _queueActive,
        IERC20Extended _nativeAsset,
        IERC20Extended _foreignAsset
    ) BasePool(_nativeAsset, _foreignAsset) {
        queueActive = _queueActive;
    }

    /* ========== VIEWS ========== */

    /* ========== MUTATIVE FUNCTIONS ========== */

    /*
     * @dev Allows burning of NFT represented by param {id} for liquidity redeeming.
     *
     * Deletes the position in {positions} mapping against the burned NFT token.
     *
     * Internally calls `_burn` function on {BasePool} contract.
     *
     * Calculates the impermanent loss incurred by the position.
     *
     * Returns the amounts for native and foreign assets sent to the {to} address
     * along with the covered loss.
     **/
    // NOTE: IL is only covered via router!
    function burn(uint256 id, address to)
        external
        override
        returns (
            uint256 amountNative,
            uint256 amountForeign,
            uint256 coveredLoss
        )
    {
        (amountNative, amountForeign) = _burn(id, to);

        Position storage position = positions[id];

        uint256 creation = position.creation;
        uint256 originalNative = position.originalNative;
        uint256 originalForeign = position.originalForeign;

        delete positions[id];

        // NOTE: Validate it behaves as expected for non-18 decimal tokens
        uint256 loss = VaderMath.calculateLoss(
            originalNative,
            originalForeign,
            amountNative,
            amountForeign
        );

        // TODO: Original Implementation Applied 100 Days
        coveredLoss =
            (loss * _min(block.timestamp - creation, _ONE_YEAR)) /
            _ONE_YEAR;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // TODO: Investigate Necessity
    function toggleQueue() external override onlyOwner {
        bool _queueActive = !queueActive;
        queueActive = _queueActive;
        emit QueueActive(_queueActive);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== PRIVATE FUNCTIONS ========== */

    /**
     * @dev Ensures only the DAO is able to invoke a particular function by validating that
     * the owner is the msg.sender, equivalent to the DAO address
     */
    function _onlyDAO() private view {
        require(
            owner == _msgSender(),
            "BasePool::_onlyDAO: Insufficient Privileges"
        );
    }

    /**
     * @dev Calculates the minimum of the two values
     */
    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /* ========== MODIFIERS ========== */

    /**
     * @dev Throws if invoked by anyone else other than the DAO
     */
    modifier onlyDAO() {
        _onlyDAO();
        _;
    }
}

contract TwapOracle is Ownable {
    /* ========== LIBRARIES ========== */

    using FixedPoint for *;

    /* ========== STRUCTURES ========== */

    struct PairData {
        // The address of the pair interface (IUniswapV2Pair or IVaderPoolV2)
        address pair;
        // The first token of the pair.
        address token0;
        // The second token of the pair.
        address token1;
        // The last cumulative price of the first token.
        uint256 price0CumulativeLast;
        // The last cumulative price of the second token.
        uint256 price1CumulativeLast;
        // The block timestamp of the last update.
        uint32 blockTimestampLast;
        // The average price of the first token.
        FixedPoint.uq112x112 price0Average;
        // The average price of the second token.
        FixedPoint.uq112x112 price1Average;
    }

    /* ========== STATE VARIABLES ========== */

    // The address of the deployed VADER token.
    address public VADER;

    // The address of the deployed USDV token.
    address public USDV;

    // A predicated which determines if USDV is enabled.
    bool private _usdvEnabled;

    // The mapping of native assets to USD aggregators.
    mapping(address => address) private _aggregators;

    // The vader pool used across all native assets.
    IVaderPoolV2 private _vaderPool;

    // The frequency that the pair collection should be updated.
    uint256 private _updatePeriod;

    // The collection of pairs tracked by the TWAP oracle.
    PairData[] private _pairs;

    // A mapping of pair hashes to existence predicates.
    mapping(bytes32 => bool) private _pairExists;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Constructs a new TWAP oracle with a VADER pool and update period.
     * @param vaderPool The VADER pool address.
     * @param updatePeriod The required period of time between each oracle update.
     */
    constructor(address vaderPool, uint256 updatePeriod) Ownable() {
        _vaderPool = IVaderPoolV2(vaderPool);
        _updatePeriod = updatePeriod;
    }

    /* ========== MODIFIERS ========== */

    modifier initialized() {
        require(
            VADER != address(0) && USDV != address(0),
            "TwapOracle::initialized: not initialized"
        );
        _;
    }

    /* ========== VIEWS ========== */

    /**
     * @dev Checks if a pair exists for the supplied {token0} and {token1} addresses.
     * @param token0 The primary token address, either VADER or USDV.
     * @param token1 The asset token address, paired to either VADER or USDV.
     */
    function pairExists(address token0, address token1)
        public
        view
        returns (bool)
    {
        bytes32 pairHash0 = keccak256(abi.encodePacked(token0, token1));
        bytes32 pairHash1 = keccak256(abi.encodePacked(token1, token0));
        return _pairExists[pairHash0] || _pairExists[pairHash1];
    }

    /**
     * @dev Performs a consultation to retrieve the equivalent to {amountIn} for the supplied {token} address.
     * The {token} address must have a registered pairing, otherwise the transaction will revert.
     * @param token The token address to consult the equivalent {amountIn} for.
     */
    function consult(address token) public view returns (uint256 result) {
        uint256 pairCount = _pairs.length;
        uint256 sumNative = 0;
        uint256 sumUSD = 0;

        for (uint256 i = 0; i < pairCount; i++) {
            PairData memory pairData = _pairs[i];

            if (token == pairData.token0) {
                //
                // TODO - Review:
                //   Verify price1Average is amount of USDV against 1 unit of token1
                //

                sumNative += 1; // native asset amount
                if (pairData.price1Average._x != 0) {
                    require(sumNative != 0);
                }

                (
                    uint80 roundID,
                    int256 price,
                    ,
                    ,
                    uint80 answeredInRound
                ) = AggregatorV3Interface(_aggregators[pairData.token1])
                        .latestRoundData();

                require(
                    answeredInRound >= roundID,
                    "TwapOracle::consult: stale chainlink price"
                );
                require(
                    price != 0,
                    "TwapOracle::consult: chainlink malfunction"
                );

                sumUSD += uint256(price) * (10**10);
            }
        }
        require(sumNative != 0, "TwapOracle::consult: Sum of native is zero");
        result = ((sumUSD * IERC20Metadata(token).decimals()) / sumNative);
    }

    /**
     * @dev Gets the exchange rate for the Vader to USDV.
     */
    function getRate() public view returns (uint256 result) {
        uint256 tUSDInUSDV = consult(USDV);
        uint256 tUSDInVader = consult(VADER);

        result = tUSDInUSDV / tUSDInVader;
    }

    /**
     * @dev Gets the VADER amount from the supplied USDV amount.
     * @param usdvAmount The amount in USDV.
     */
    function usdvtoVader(uint256 usdvAmount) external view returns (uint256) {
        return usdvAmount * getRate();
    }

    /**
     * @dev Gets the USDV amount from the supplied VADER amount.
     * @param vaderAmount The amount in VADER.
     */
    function vaderToUsdv(uint256 vaderAmount) external view returns (uint256) {
        if (!_usdvEnabled) {
            // consult call returns true USD amount against 1 Vader and is multiplied with {vaderAmount}.
            return consult(VADER) * vaderAmount;
        }

        // usdv price is disabled so true USD value of both Vader and USDV is taken into account.
        return vaderAmount / getRate();
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @dev Initializes the variables for VADER and USDV.
     * @param _usdv The USDV token address.
     * @param _vader The VADER token address.
     */
    function initialize(address _usdv, address _vader) external onlyOwner {
        require(
            VADER == address(0),
            "TwapOracle::initialize: Vader already set"
        );
        require(USDV == address(0), "TwapOracle::initialize: USDV already set");
        require(
            _usdv != address(0),
            "TwapOracle::initialize: can not set to a zero address"
        );
        require(
            _vader != address(0),
            "TwapOracle::initialize: can not set to a zero address"
        );

        VADER = _vader;
        USDV = _usdv;
    }

    /**
     * @dev Enables utilization of USDV.
     */
    function enableUSDV() external onlyOwner {
        _usdvEnabled = true;
    }

    /**
     * @dev Registers a chainlink {aggregator} for the supplied {asset} address.
     * @param asset The address of the native asset.
     * @param aggregator The address of the chainlink aggregator.
     */
    function registerAggregator(address asset, address aggregator)
        external
        onlyOwner
        initialized
    {
        require(
            asset != address(0),
            "TwapOracle::registerAggregator: asset zero address provided"
        );
        require(
            aggregator != address(0),
            "TwapOracle::registerAggregator: aggregator zero address provided"
        );
        require(
            _aggregators[asset] == address(0),
            "TwapOracle::registerAggregator: aggregator already exists"
        );

        _aggregators[asset] = aggregator;
    }

    /**
     * @dev Registers either a VADER or USDV pairing in the TWAP oracle.
     * @param factory The factory address, if any.
     * @param token0 The primary token address, either VADER or USDV.
     * @param token1 The asset token address, paired to VADER or USDV.
     */
    function registerPair(
        address factory,
        address token0,
        address token1
    ) external onlyOwner initialized {
        require(
            token0 == VADER || token0 == USDV,
            "TwapOracle::registerPair: Invalid token0 address"
        );
        require(
            token0 != token1,
            "TwapOracle::registerPair: Same token address"
        );
        require(
            !pairExists(token0, token1),
            "TwapOracle::registerPair: Pair exists"
        );

        address pairAddr;
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        uint112 reserve0;
        uint112 reserve1;
        uint32 blockTimestampLast;

        if (token0 == VADER) {
            IUniswapV2Pair pair = IUniswapV2Pair(
                IUniswapV2Factory(factory).getPair(token0, token1)
            );
            pairAddr = address(pair);
            price0CumulativeLast = pair.price0CumulativeLast();
            price1CumulativeLast = pair.price1CumulativeLast();
            (reserve0, reserve1, blockTimestampLast) = pair.getReserves();
        } else {
            pairAddr = address(_vaderPool);
            (price0CumulativeLast, price1CumulativeLast, ) = _vaderPool
                .cumulativePrices(IERC20(token1));
            (reserve0, reserve1, blockTimestampLast) = _vaderPool.getReserves(
                IERC20(token1)
            );
        }

        require(
            reserve0 != 0 && reserve1 != 0,
            "TwapOracle::registerPair: No reserves"
        );

        _pairExists[keccak256(abi.encodePacked(token0, token1))] = true;

        _pairs.push(
            PairData({
                pair: pairAddr,
                token0: token0,
                token1: token1,
                price0CumulativeLast: price0CumulativeLast,
                price1CumulativeLast: price1CumulativeLast,
                blockTimestampLast: blockTimestampLast,
                price0Average: FixedPoint.uq112x112({_x: 0}),
                price1Average: FixedPoint.uq112x112({_x: 0})
            })
        );
    }

    /**
     * @dev Updates the average prices for all token pairs registered in the TWAP oracle.
     */
    function update() external onlyOwner initialized {
        uint256 pairCount = _pairs.length;

        // Update all of the registered pairs in the TWAP oracle.
        for (uint256 i = 0; i < pairCount; i++) {
            PairData storage pairData = _pairs[i];

            // Get the current cumulative prices and block timestamp of the current pairing.
            (
                uint256 price0Cumulative,
                uint256 price1Cumulative,
                uint32 blockTimestamp
            ) = (pairData.token0 == VADER)
                    ? UniswapV2OracleLibrary.currentCumulativePrices(
                        pairData.pair
                    )
                    : _vaderPool.cumulativePrices(IERC20(pairData.token1));

            unchecked {
                // Ensure that at least one full period has passed since the pairing was last update.
                uint32 timeElapsed = blockTimestamp -
                    pairData.blockTimestampLast;
                require(
                    timeElapsed >= _updatePeriod,
                    "TwapOracle::update: Period not elapsed"
                );

                // Cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed.
                pairData.price0Average = FixedPoint.uq112x112(
                    uint224(
                        (price0Cumulative - pairData.price0CumulativeLast) /
                            timeElapsed
                    )
                );
                pairData.price1Average = FixedPoint.uq112x112(
                    uint224(
                        (price1Cumulative - pairData.price1CumulativeLast) /
                            timeElapsed
                    )
                );
            }

            // Update the stored pairing data
            pairData.price0CumulativeLast = price0Cumulative;
            pairData.price1CumulativeLast = price1Cumulative;
            pairData.blockTimestampLast = blockTimestamp;
        }
    }
}

/*
 @dev Implementation of {VaderRouter} contract.
 *
 * The contract VaderRouter inherits from {Ownable} and {ProtocolConstants} contracts.
 *
 * It allows adding of liquidity to Vader pools and facilitate creation of Vader pools if
 * it does not already exist when depositing liquidity.
 *
 * Allows removing of liquidity by the users and claiming the underlying assets from
 * the Vader pools.
 *
 * Allows swapping between native and foreign assets within a single Vader pool.
 *
 * Allows swapping of foreign assets across two different Vader pools.
 *
 * Contains helper functions to compute the destination asset amount given the exact source
 * asset amount and vice versa.
 **/
contract VaderRouter is IVaderRouter, ProtocolConstants, Ownable {
    /* ========== LIBRARIES ========== */

    // Used for safe token transfers
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // The address of Vader pool factory contract.
    IVaderPoolFactory public immutable factory;

    // The address of Reserve contract.
    IVaderReserve public reserve;

    /* ========== CONSTRUCTOR ========== */

    /*
     * @dev Initializes contract's state by setting the vader pool factory address.
     *
     * Requirements:
     * - Vader pool factory address must not be zero.
     **/
    constructor(IVaderPoolFactory _factory) {
        require(
            _factory != IVaderPoolFactory(_ZERO_ADDRESS),
            "VaderRouter::constructor: Incorrect Arguments"
        );

        factory = _factory;
    }

    /* ========== VIEWS ========== */

    /* ========== MUTATIVE FUNCTIONS ========== */

    /*
     * @dev Allows adding of liquidity to the Vader pools.
     *
     * Internally calls {addLiquidity} function.
     *
     * Returns the amounts of assetA and assetB used in liquidity and
     * the amount of liquidity units minted.
     **/
    // NOTE: For Uniswap V2 compliancy, necessary due to stack too deep
    function addLiquidity(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256, // amountAMin = unused
        uint256, // amountBMin = unused
        address to,
        uint256 deadline
    )
        external
        override
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        return
            addLiquidity(
                tokenA,
                tokenB,
                amountADesired,
                amountBDesired,
                to,
                deadline
            );
    }

    /*
     * @dev Allows adding of liquidity to the Vader pools.
     *
     * Internally calls {_addLiquidity} function.
     *
     * Transfers the amounts of tokenA and tokenB from {msg.sender} to the pool.
     *
     * Calls the {mint} function on the pool to deposit liquidity on the behalf of
     * {to} address.
     *
     * Returns the amounts of assetA and assetB used in liquidity and
     * the amount of liquidity units minted.
     *
     * Requirements:
     * - The current timestamp has not exceeded the param {deadline}.
     **/
    function addLiquidity(
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        address to,
        uint256 deadline
    )
        public
        override
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        IVaderPool pool;
        (pool, amountA, amountB) = _addLiquidity(
            address(tokenA),
            address(tokenB),
            amountADesired,
            amountBDesired
        );
        tokenA.safeTransferFrom(msg.sender, address(pool), amountA);
        tokenB.safeTransferFrom(msg.sender, address(pool), amountB);
        liquidity = pool.mint(to);
    }

    /*
     * @dev Allows removing of liquidity by {msg.sender} and transfers the
     * underlying assets to {to} address.
     *
     * Transfers the NFT with Id {id} representing user's position, to the pool address,
     * so the pool is able to burn it in the `burn` function call.
     *
     * Calls the `burn` function on the pool contract.
     *
     * Calls the `reimburseImpermanentLoss` on reserve contract to cover impermanent loss
     * for the liquidity being removed.
     *
     * Requirements:
     * - The underlying assets amounts of {amountA} and {amountB} must
     *   be greater than or equal to {amountAMin} and {amountBMin}, respectively.
     * - The current timestamp has not exceeded the param {deadline}.
     **/
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 id,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        public
        override
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        IVaderPool pool = factory.getPool(tokenA, tokenB);

        pool.transferFrom(msg.sender, address(pool), id);

        (
            uint256 amountNative,
            uint256 amountForeign,
            uint256 coveredLoss
        ) = pool.burn(id, to);

        (amountA, amountB) = tokenA == factory.nativeAsset()
            ? (amountNative, amountForeign)
            : (amountForeign, amountNative);

        require(
            amountA >= amountAMin,
            "UniswapV2Router: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountB >= amountBMin,
            "UniswapV2Router: INSUFFICIENT_B_AMOUNT"
        );

        reserve.reimburseImpermanentLoss(msg.sender, coveredLoss);
    }

    /*
     * @dev Allows swapping of exact source token amount to destination
     * token amount.
     *
     * Internally calls {_swap} function.
     *
     * Requirements:
     * - The destination amount {amountOut} must greater than or equal to param {amountOutMin}.
     * - The current timestamp has not exceeded the param {deadline}.
     **/
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) returns (uint256 amountOut) {
        amountOut = _swap(amountIn, path, to);

        require(
            amountOut >= amountOutMin,
            "VaderRouter::swapExactTokensForTokens: Insufficient Trade Output"
        );
    }

    /*
     * @dev Allows swapping of source token amount to exact destination token
     * amount.
     *
     * Internally calls {calculateInGivenOut} and {_swap} functions.
     *
     * Requirements:
     * - Param {amountInMax} must be greater than or equal to the source amount computed {amountIn}.
     * - The current timestamp has not exceeded the param {deadline}.
     **/
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) returns (uint256 amountIn) {
        amountIn = calculateInGivenOut(amountOut, path);

        require(
            amountInMax >= amountIn,
            "VaderRouter::swapTokensForExactTokens: Large Trade Input"
        );

        _swap(amountIn, path, to);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /*
     * @dev Sets the reserve address and renounces contract's ownership.
     *
     * Requirements:
     * - Only existing owner can call this function.
     * - Param {_reserve} cannot be a zero address.
     **/
    function initialize(IVaderReserve _reserve) external onlyOwner {
        require(
            _reserve != IVaderReserve(_ZERO_ADDRESS),
            "VaderRouter::initialize: Incorrect Reserve Specified"
        );

        reserve = _reserve;

        // renounceOwnership();
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== PRIVATE FUNCTIONS ========== */

    /*
     * @dev Allows swapping of assets from within a single Vader pool or
     * across two different Vader pools.
     *
     * In case of a single Vader pool, the native asset can be swapped for foreign
     * asset and vice versa.
     *
     * In case of two Vader pools, the foreign asset is swapped for native asset from
     * the first Vader pool and the native asset retrieved from the first Vader pool is swapped
     * for foreign asset from the second Vader pool.
     *
     * Requirements:
     * - Param {path} length can be either 2 or 3.
     * - If the {path} length is 3 the index 0 and 1 must contain foreign assets' addresses
     *   and index 1 must contain native asset's address.
     * - If the {path} length is 2 then either of indexes must contain foreign asset's address
     *   and the other one must contain native asset's address.
     **/
    // TODO: Refactor with central pool, perhaps diminishes security? would need directSwap & bridgeSwap
    function _swap(
        uint256 amountIn,
        address[] calldata path,
        address to
    ) private returns (uint256 amountOut) {
        if (path.length == 3) {
            require(
                path[0] != path[1] &&
                    path[1] == factory.nativeAsset() &&
                    path[2] != path[1],
                "VaderRouter::_swap: Incorrect Path"
            );

            IVaderPool pool0 = factory.getPool(path[0], path[1]);
            IVaderPool pool1 = factory.getPool(path[1], path[2]);

            IERC20(path[0]).safeTransferFrom(
                msg.sender,
                address(pool0),
                amountIn
            );

            return pool1.swap(0, pool0.swap(amountIn, 0, address(pool1)), to);
        } else {
            require(
                path.length == 2,
                "VaderRouter::_swap: Incorrect Path Length"
            );
            address nativeAsset = factory.nativeAsset();
            require(path[0] != path[1], "VaderRouter::_swap: Incorrect Path");

            IVaderPool pool = factory.getPool(path[0], path[1]);
            IERC20(path[0]).safeTransferFrom(
                msg.sender,
                address(pool),
                amountIn
            );
            if (path[0] == nativeAsset) {
                return pool.swap(amountIn, 0, to);
            } else {
                require(
                    path[1] == nativeAsset,
                    "VaderRouter::_swap: Incorrect Path"
                );
                return pool.swap(0, amountIn, to);
            }
        }
    }

    /*
     * @dev An internal function that returns Vader pool's address against
     * the provided assets of {tokenA} and {tokenB} if it exists, otherwise
     * a new Vader pool created against the provided assets.
     **/
    // NOTE: DEX allows asymmetric deposits
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    )
        private
        returns (
            IVaderPool pool,
            uint256 amountA,
            uint256 amountB
        )
    {
        // create the pair if it doesn't exist yet
        pool = factory.getPool(tokenA, tokenB);
        if (pool == IVaderPool(_ZERO_ADDRESS)) {
            pool = factory.createPool(tokenA, tokenB);
        }

        (amountA, amountB) = (amountADesired, amountBDesired);
    }

    /*
     * @dev Returns the amount of source asset given the amount of destination asset.
     *
     * Calls the {calculateSwapReverse} on VaderMath library to compute the source
     * token amount.
     *
     * Requirements:
     * - Param {path} length can be either 2 or 3.
     * - If the {path} length is 3 the index 0 and 1 must contain foreign assets' addresses
     *   and index 1 must contain native asset's address.
     * - If the {path} length is 2 then either of indexes must contain foreign asset's address
     *   and the other one must contain native asset's address.
     **/
    function calculateInGivenOut(uint256 amountOut, address[] calldata path)
        public
        view
        returns (uint256 amountIn)
    {
        if (path.length == 2) {
            address nativeAsset = factory.nativeAsset();
            IVaderPool pool = factory.getPool(path[0], path[1]);
            (uint256 nativeReserve, uint256 foreignReserve, ) = pool
                .getReserves();
            if (path[0] == nativeAsset) {
                return
                    VaderMath.calculateSwapReverse(
                        amountOut,
                        nativeReserve,
                        foreignReserve
                    );
            } else {
                return
                    VaderMath.calculateSwapReverse(
                        amountOut,
                        foreignReserve,
                        nativeReserve
                    );
            }
        } else {
            IVaderPool pool0 = factory.getPool(path[0], path[1]);
            IVaderPool pool1 = factory.getPool(path[1], path[2]);
            (uint256 nativeReserve0, uint256 foreignReserve0, ) = pool0
                .getReserves();
            (uint256 nativeReserve1, uint256 foreignReserve1, ) = pool1
                .getReserves();

            return
                VaderMath.calculateSwapReverse(
                    VaderMath.calculateSwapReverse(
                        amountOut,
                        nativeReserve1,
                        foreignReserve1
                    ),
                    foreignReserve0,
                    nativeReserve0
                );
        }
    }

    /*
     * @dev Returns the amount of destination asset given the amount of source asset.
     *
     * Calls the {calculateSwap} on VaderMath library to compute the destination
     * token amount.
     *
     * Requirements:
     * - Param {path} length can be either 2 or 3.
     * - If the {path} length is 3 the index 0 and 1 must contain foreign assets' addresses
     *   and index 1 must contain native asset's address.
     * - If the {path} length is 2 then either of indexes must contain foreign asset's address
     *   and the other one must contain native asset's address.
     **/
    function calculateOutGivenIn(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256 amountOut)
    {
        if (path.length == 2) {
            address nativeAsset = factory.nativeAsset();
            IVaderPool pool = factory.getPool(path[0], path[1]);
            (uint256 nativeReserve, uint256 foreignReserve, ) = pool
                .getReserves();
            if (path[0] == nativeAsset) {
                return
                    VaderMath.calculateSwap(
                        amountIn,
                        nativeReserve,
                        foreignReserve
                    );
            } else {
                return
                    VaderMath.calculateSwap(
                        amountIn,
                        foreignReserve,
                        nativeReserve
                    );
            }
        } else {
            IVaderPool pool0 = factory.getPool(path[0], path[1]);
            IVaderPool pool1 = factory.getPool(path[1], path[2]);
            (uint256 nativeReserve0, uint256 foreignReserve0, ) = pool0
                .getReserves();
            (uint256 nativeReserve1, uint256 foreignReserve1, ) = pool1
                .getReserves();

            return
                VaderMath.calculateSwap(
                    VaderMath.calculateSwap(
                        amountIn,
                        nativeReserve1,
                        foreignReserve1
                    ),
                    foreignReserve0,
                    nativeReserve0
                );
        }
    }

    /* ========== MODIFIERS ========== */

    // Guard ensuring that the current timestamp has not exceeded the param {deadline}.
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "VaderRouter::ensure: Expired");
        _;
    }
}

contract LPWrapper is ILPWrapper, ProtocolConstants, Ownable {
    mapping(IERC20 => IERC20Extended) public override tokens;

    constructor(address pool) {
        require(
            pool != _ZERO_ADDRESS,
            "LPWrapper::constructor: Misconfiguration"
        );
        // transferOwnership(pool);
    }

    function createWrapper(IERC20 foreignAsset) external override onlyOwner {
        require(
            tokens[foreignAsset] == IERC20Extended(_ZERO_ADDRESS),
            "LPWrapper::createWrapper: Already Created"
        );

        // NOTE: Here, `owner` is the VaderPoolV2
        tokens[foreignAsset] = IERC20Extended(
            address(
                new LPToken(
                    IERC20Extended(address(foreignAsset)),
                    IVaderPoolV2(owner)
                )
            )
        );
    }
}

/*
 * @dev Implementation of {VaderPoolFactory} contract.
 *
 * The VaderPoolFactory contract inherits from {Ownable} and {ProtocolConstants} contracts.
 *
 * Keeps track of all the created Vader pools through {getPool} mapping and
 * {allPools} array. Also stores the address of asset used as native asset
 * across all of the Vader pools created through the factory.
 *
 * Allows creation of new Vader pools.
 **/
contract VaderPoolFactory is IVaderPoolFactory, ProtocolConstants, Ownable {
    /* ========== STATE VARIABLES ========== */

    // Denotes whether the queue system is active on new pairs, disabled by default
    bool public queueActive;

    // Native Asset of the system
    address public override nativeAsset;

    // Token A -> Token B -> Pool mapping
    mapping(address => mapping(address => IVaderPool)) public override getPool;

    // A list of all pools
    IVaderPool[] public allPools;

    /* ========== VIEWS ========== */

    /* ========== MUTATIVE FUNCTIONS ========== */

    /*
     * @dev Allows creation of a Vader pool of native and foreign assets.
     *
     * Populates the {getPool} mapping with the newly created Vader pool and
     * pushes this pool to {allPools} array.
     *
     * Requirements:
     * - Native and foreign assets cannot be the same.
     * - Foreign asset cannot be the zero address.
     * - The pool against the specified foreign asset does not already exist.
     **/
    // NOTE: Between deployment & initialization may be corrupted but chance small
    function createPool(address tokenA, address tokenB)
        external
        override
        returns (IVaderPool pool)
    {
        (address token0, address token1) = tokenA == nativeAsset
            ? (tokenA, tokenB)
            : tokenB == nativeAsset
            ? (tokenB, tokenA)
            : (_ZERO_ADDRESS, _ZERO_ADDRESS);

        require(
            token0 != token1,
            "VaderPoolFactory::createPool: Identical Tokens"
        );

        require(
            token1 != _ZERO_ADDRESS,
            "VaderPoolFactory::createPool: Inexistent Token"
        );

        require(
            getPool[token0][token1] == IVaderPool(_ZERO_ADDRESS),
            "VaderPoolFactory::createPool: Pair Exists"
        ); // single check is sufficient

        pool = new VaderPool(
            queueActive,
            IERC20Extended(token0),
            IERC20Extended(token1)
        );
        getPool[token0][token1] = pool;
        getPool[token1][token0] = pool; // populate mapping in the reverse direction
        allPools.push(pool);
        emit PoolCreated(token0, token1, pool, allPools.length);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /*
     * @dev Allows initializing of the factory contract by owner by setting the
     * address of native asset for all the Vader pool and also transferring the
     * contract's ownership to {_dao}.
     *
     * Requirements:
     * - Only onwer can call this function.
     **/
    function initialize(address _nativeAsset, address _dao) external onlyOwner {
        require(
            _nativeAsset != _ZERO_ADDRESS && _dao != _ZERO_ADDRESS,
            "VaderPoolFactory::initialize: Incorrect Arguments"
        );

        nativeAsset = _nativeAsset;
        // transferOwnership(_dao);
    }

    /*
     * @dev Allows toggling of queue system of a pool.
     *
     * Requirements:
     * - This function can only be called when DAO is active.
     **/
    function toggleQueue(address token0, address token1) external onlyDAO {
        getPool[token0][token1].toggleQueue();
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /* ========== PRIVATE FUNCTIONS ========== */

    /**
     * @dev Ensures only the DAO is able to invoke a particular function by validating that
     * the owner is the msg.sender, equivalent to the DAO address, and that the native asset
     * has been set
     */
    function _onlyDAO() private view {
        require(
            nativeAsset != _ZERO_ADDRESS && owner == msg.sender,
            "BasePool::_onlyDAO: Insufficient Privileges"
        );
    }

    /* ========== MODIFIERS ========== */

    /**
     * @dev Throws if invoked by anyone else other than the DAO
     */
    modifier onlyDAO() {
        _onlyDAO();
        _;
    }
}

