// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {EthCredits} from "./common/EthCredits.sol";

/// @notice Single-round operator commit/reveal raffle with a forfeitable operator bond.
/// @dev Operator-known entropy is NOT unbiased randomness. See ANALYSIS.md before using real value.
contract Raffle is EthCredits {
    error Unauthorized();
    error InvalidInput();
    error WrongState();
    enum State {
        Created,
        Open,
        Drawn,
        Expired
    }
    State public state;
    address public immutable operator;
    uint256 public immutable ticketPrice;
    uint256 public immutable maxTickets;
    uint256 public immutable saleDuration;
    uint256 public immutable revealDuration;
    bytes32 public commitment;
    uint256 public saleEnd;
    uint256 public revealEnd;
    uint256 public bond;
    uint256 public ticketCount;
    uint256 public refundPerTicket;
    address public winner;
    mapping(uint256 => address) public ticketOwner;
    mapping(address => uint256) public ticketsHeld;
    event Opened(bytes32 commitment, uint256 saleEnd, uint256 revealEnd, uint256 bond);
    event TicketBought(uint256 indexed ticket, address indexed buyer);
    event Drawn(bytes32 seed, address indexed winner, uint256 prize);
    event Expired(uint256 refundPerTicket);
    event Refunded(address indexed account, uint256 tickets, uint256 amount);

    constructor(address roundOperator, uint256 price, uint256 cap, uint256 sales, uint256 revealWindow) {
        if (
            roundOperator == address(0) || price == 0 || cap == 0 || cap > 10000 || sales < 1 hours
                || sales > 30 days || revealWindow < 1 hours || revealWindow > 7 days
        ) revert InvalidInput();
        operator = roundOperator;
        ticketPrice = price;
        maxTickets = cap;
        saleDuration = sales;
        revealDuration = revealWindow;
    }

    /// @notice Operator commits before sales and posts a bond at least equal to the maximum ticket revenue.
    function open(bytes32 seedCommitment) external payable nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        if (state != State.Created) revert WrongState();
        if (seedCommitment == bytes32(0) || msg.value < maxTickets * ticketPrice) revert InvalidInput();
        commitment = seedCommitment;
        bond = msg.value;
        state = State.Open;
        saleEnd = block.timestamp + saleDuration;
        revealEnd = saleEnd + revealDuration;
        emit Opened(seedCommitment, saleEnd, revealEnd, msg.value);
    }

    /// @notice Buy one ticket for exact payment before the sale deadline and hard cap.
    function buyTicket() external payable nonReentrant {
        if (state != State.Open || block.timestamp >= saleEnd || ticketCount >= maxTickets) {
            revert WrongState();
        }
        if (msg.value != ticketPrice) revert InvalidInput();
        uint256 id = ticketCount++;
        ticketOwner[id] = msg.sender;
        ++ticketsHeld[msg.sender];
        emit TicketBought(id, msg.sender);
    }

    /// @notice Reveal keccak256(abi.encode(seed, this contract, chainId)); prize and bond become pull credits.
    function reveal(bytes32 seed) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        if (state != State.Open || block.timestamp < saleEnd || block.timestamp >= revealEnd) {
            revert WrongState();
        }
        if (keccak256(abi.encode(seed, address(this), block.chainid)) != commitment) revert InvalidInput();
        state = State.Drawn;
        _credit(operator, bond);
        if (ticketCount > 0) {
            winner = ticketOwner[uint256(keccak256(abi.encode(seed, commitment))) % ticketCount];
            _credit(winner, ticketCount * ticketPrice);
        }
        emit Drawn(seed, winner, ticketCount * ticketPrice);
    }

    /// @notice Anyone expires a round whose reveal failed; bond is shared equally per sold ticket.
    function expire() external nonReentrant {
        if (state != State.Open || block.timestamp < revealEnd) revert WrongState();
        state = State.Expired;
        if (ticketCount > 0) {
            refundPerTicket = ticketPrice + bond / ticketCount;
            _credit(operator, bond % ticketCount);
        } else {
            _credit(operator, bond);
        }
        emit Expired(refundPerTicket);
    }

    /// @notice Convert all caller tickets in an expired round into a pull refund plus their bond share.
    function refund() external nonReentrant {
        if (state != State.Expired) revert WrongState();
        uint256 count = ticketsHeld[msg.sender];
        if (count == 0) revert InvalidInput();
        ticketsHeld[msg.sender] = 0;
        uint256 amount = count * refundPerTicket;
        _credit(msg.sender, amount);
        emit Refunded(msg.sender, count, amount);
    }
}
