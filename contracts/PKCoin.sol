/*
Implements ERC 20 Token standard: https://github.com/ethereum/EIPs/issues/20.
*/
pragma solidity ^0.4.11;


import "zeppelin/token/StandardToken.sol";


contract pkcoin is StandardToken {

    // data structures
    enum States {
    Initial, // deployment time
    ValuationSet,
    Ico, // whitelist addresses, accept funds, update balances
    Underfunded, // ICO time finished and minimal amount not raised
    Operational, // manage contests
    Paused         // for contract upgrades
    }

    //should be constant, but is not, to avoid compiler warning
    address public  rakeEventPlaceholderAddress = 0x0000000000000000000000000000000000000000;

    string public constant name = "pkcoin";

    string public constant symbol = "PLAY";

    uint8 public constant decimals = 18;

    mapping (address => bool) public whitelist;

    address public initialHolder;

    address public stateControl;

    address public whitelistControl;

    address public withdrawControl;

    States public state;

    uint256 public weiICOMinimum;

    uint256 public weiICOMaximum;

    uint256 public silencePeriod;

    uint256 public startAcceptingFundsBlock;

    uint256 public endBlock;

    uint256 public ETH_PKCOIN; //number of pkcoins per ETH

    mapping (address => uint256) lastRakePoints;


    uint256 pointMultiplier = 1e18; //100% = 1*10^18 points
    uint256 totalRakePoints; //total amount of rakes ever paid out as a points value. increases monotonically, but the number range is 2^256, that's enough.
    uint256 unclaimedRakes; //amount of planet kids coins unclaimed. acts like a special entry to balances
    uint256 constant percentForSale = 30;

    mapping (address => bool) public contests; // true if this address holds a contest

    //this creates the contract and stores the owner. it also passes in 3 addresses to be used later during the lifetime of the contract.
    function pkcoin(address _stateControl, address _whitelistControl, address _withdraw, address _initialHolder) {
        initialHolder = _initialHolder;
        stateControl = _stateControl;
        whitelistControl = _whitelistControl;
        withdrawControl = _withdraw;
        moveToState(States.Initial);
        weiICOMinimum = 0;
        //to be overridden
        weiICOMaximum = 0;
        endBlock = 0;
        ETH_PKCOIN = 0;
        totalSupply = 2000000000 * pointMultiplier;
        //sets the value in the superclass.
        balances[initialHolder] = totalSupply;
        //initially, initialHolder has 100%
    }

    event ContestAnnouncement(address addr);

    event Whitelisted(address addr);

    event Credited(address addr, uint balance, uint txAmount);

    event StateTransition(States oldState, States newState);

    modifier onlyWhitelist() {
        require(msg.sender == whitelistControl);
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == initialHolder);
        _;
    }

    modifier onlyStateControl() {
        require(msg.sender == stateControl);
        _;
    }

    modifier onlyWithdraw() {
        require(msg.sender == withdrawControl);
        _;
    }

    modifier requireState(States _requiredState) {
        require(state == _requiredState);
        _;
    }

    /**
    BEGIN ICO functions
    */

    //this is the main funding function, it updates the balances of Planet Kids Coins during the ICO.
    //no particular incentive schemes have been implemented here
    //it is only accessible during the "ICO" phase.
    function() payable
    requireState(States.Ico)
    {
        require(whitelist[msg.sender] == true);
        require(this.balance <= weiICOMaximum); //note that msg.value is already included in this.balance
        require(block.number < endBlock);
        require(block.number >= startAcceptingFundsBlock);
        uint256 pkcoinIncrease = msg.value * ETH_PKCOIN;
        balances[initialHolder] -= pkcoinIncrease;
        balances[msg.sender] += pkcoinIncrease;
        Credited(msg.sender, balances[msg.sender], msg.value);
    }

    function moveToState(States _newState)
    internal
    {
        StateTransition(state, _newState);
        state = _newState;
    }

    // ICO contract configuration function
    // newEthICOMinimum is the minimum amount of funds to raise
    // newEthICOMaximum is the maximum amount of funds to raise
    // silencePeriod is a number of blocks to wait after starting the ICO. No funds are accepted during the silence period. It can be set to zero.
    // newEndBlock is the absolute block number at which the ICO must stop. It must be set after now + silence period.
    function updateEthICOThresholds(uint256 _newWeiICOMinimum, uint256 _newWeiICOMaximum, uint256 _silencePeriod, uint256 _newEndBlock)
    onlyStateControl
    {
        require(state == States.Initial || state == States.ValuationSet);
        require(_newWeiICOMaximum > _newWeiICOMinimum);
        require(block.number + silencePeriod < _newEndBlock);
        require(block.number < _newEndBlock);
        weiICOMinimum = _newWeiICOMinimum;
        weiICOMaximum = _newWeiICOMaximum;
        silencePeriod = _silencePeriod;
        endBlock = _newEndBlock;
        // initial conversion rate of ETH_PKCOIN set now, this is used during the Ico phase.
        ETH_PKCOIN = ((totalSupply * percentForSale) / 100) / weiICOMaximum;
        // check pointMultiplier
        moveToState(States.ValuationSet);
    }

    function startICO()
    onlyStateControl
    requireState(States.ValuationSet)
    {
        require(block.number < endBlock);
        require(block.number + silencePeriod < endBlock);
        startAcceptingFundsBlock = block.number + silencePeriod;
        moveToState(States.Ico);
    }


    function endICO()
    onlyStateControl
    requireState(States.Ico)
    {
        if (this.balance < weiICOMinimum) {
            moveToState(States.Underfunded);
        }
        else {
            burnUnsoldCoins();
            moveToState(States.Operational);
        }
    }

    function anyoneEndICO()
    requireState(States.Ico)
    {
        require(block.number > endBlock);
        if (this.balance < weiICOMinimum) {
            moveToState(States.Underfunded);
        }
        else {
            burnUnsoldCoins();
            moveToState(States.Operational);
        }
    }

    function burnUnsoldCoins()
    internal
    {
        uint256 soldcoins = this.balance * ETH_PKCOIN;
        totalSupply = soldcoins * 100 / percentForSale;
        balances[initialHolder] = totalSupply - soldcoins;
        //slashing the initial supply, so that the ico is selling 30% total
    }

    function addToWhitelist(address _whitelisted)
    onlyWhitelist
        //    requireState(States.Ico)
    {
        whitelist[_whitelisted] = true;
        Whitelisted(_whitelisted);
    }


    //emergency pause for the ICO
    function pause()
    onlyStateControl
    requireState(States.Ico)
    {
        moveToState(States.Paused);
    }

    //in case we want to completely abort
    function abort()
    onlyStateControl
    requireState(States.Paused)
    {
        moveToState(States.Underfunded);
    }

    //un-pause
    function resumeICO()
    onlyStateControl
    requireState(States.Paused)
    {
        moveToState(States.Ico);
    }

    //in case of a failed/aborted ICO every investor can get back their money
    function requestRefund()
    requireState(States.Underfunded)
    {
        require(balances[msg.sender] > 0);
        //there is no need for updateAccount(msg.sender) since the token never became active.
        uint256 payout = balances[msg.sender] / ETH_PKCOIN;
        //reverse calculate the amount to pay out
        balances[msg.sender] = 0;
        msg.sender.transfer(payout);
    }

    //after the ico has run its course, the withdraw account can drain funds bit-by-bit as needed.
    function requestPayout(uint _amount)
    onlyWithdraw //very important!
    requireState(States.Operational)
    {
        msg.sender.transfer(_amount);
    }
    /**
    END ICO functions
    */

    /**
    BEGIN ERC20 functions
    */
    function transfer(address _to, uint256 _value)
    requireState(States.Operational)
    updateAccount(msg.sender) //update senders rake before transfer, so they can access their full balance
    updateAccount(_to) //update receivers rake before transfer as well, to avoid over-attributing rake
    enforceRake(msg.sender, _value)
    returns (bool success) {
        return super.transfer(_to, _value);
    }

    function transferFrom(address _from, address _to, uint256 _value)
    requireState(States.Operational)
    updateAccount(_from) //update senders rake before transfer, so they can access their full balance
    updateAccount(_to) //update receivers rake before transfer as well, to avoid over-attributing rake
    enforceRake(_from, _value)
    returns (bool success) {
        return super.transferFrom(_from, _to, _value);
    }

    function balanceOf(address _account)
    constant
    returns (uint256 balance) {
        return balances[_account] + rakesOwing(_account);
    }

    function payRake(uint256 _value)
    requireState(States.Operational)
    updateAccount(msg.sender)
    returns (bool success) {
        return payRakeInternal(msg.sender, _value);
    }


    function
    payRakeInternal(address _sender, uint256 _value)
    internal
    returns (bool success) {

        if (balances[_sender] <= _value) {
            return false;
        }
        if (_value != 0) {
            Transfer(_sender, rakeEventPlaceholderAddress, _value);
            balances[_sender] -= _value;
            unclaimedRakes += _value;
            //   calc amount of points from total:
            uint256 pointsPaid = _value * pointMultiplier / totalSupply;
            totalRakePoints += pointsPaid;
        }
        return true;

    }
    /**
    END ERC20 functions
    */
    /**
    BEGIN Rake modifier updateAccount
    */
    modifier updateAccount(address _account) {
        uint256 owing = rakesOwing(_account);
        if (owing != 0) {
            unclaimedRakes -= owing;
            balances[_account] += owing;
            Transfer(rakeEventPlaceholderAddress, _account, owing);
        }
        //also if 0 this needs to be called, since lastRakePoints need the right value
        lastRakePoints[_account] = totalRakePoints;
        _;
    }

    //todo use safemath.sol
    function rakesOwing(address _account)
    internal
    constant
    returns (uint256) {//returns always > 0 value
        //how much is _account owed, denominated in points from total supply
        uint256 newRakePoints = totalRakePoints - lastRakePoints[_account];
        //always positive
        //weigh by my balance (dimension HC*10^18)
        uint256 basicPoints = balances[_account] * newRakePoints;
        //still positive
        //normalize to dimension HC by moving comma left by 18 places
        return (basicPoints) / pointMultiplier;
    }
    /**
    END Rake modifier updateAccount
    */

    // contest management functions

    modifier enforceRake(address _contest, uint256 _value){
        //we calculate 1% of the total value, rounded up. division would round down otherwise.
        //explicit brackets illustrate that the calculation only round down when dividing by 100, to avoid an expression
        // like value * (99/100)
        if (contests[_contest]) {
            uint256 toPay = _value - ((_value * 99) / 100);
            bool paid = payRakeInternal(_contest, toPay);
            require(paid);
        }
        _;
    }

    // all functions require pkcoin operational state


    // registerContest declares a contest to pkcoin.
    // It must be called from an address that has pkcoin.
    // This address is recorded as the contract admin.
    function registerContest()
    {
        contests[msg.sender] = true;
        ContestAnnouncement(msg.sender);
    }
}
