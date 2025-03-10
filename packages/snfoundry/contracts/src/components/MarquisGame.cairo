// SPDX-License-Identifier: MIT
// @author : Carlos Ramos
// @notice : Base component for all The-Marquis-Game contracts

use starknet::ContractAddress;

#[starknet::component]
pub mod MarquisGame {
    use contracts::IMarquisCore::{
        Constants, IMarquisCoreDispatcher, IMarquisCoreDispatcherTrait, SupportedToken,
    };
    use contracts::interfaces::IMarquisGame::{
        ForcedSessionFinished, GameErrors, GameStatus, IMarquisGame, InitParams, Session,
        SessionCreated, SessionData, SessionErrors, SessionJoined, VerifiableRandomNumber,
    };

    use core::num::traits::Zero;
    use core::panic_with_felt252;
    use core::traits::Into;
    use openzeppelin_access::ownable::OwnableComponent;
    //use keccak::keccak_u256s_le_inputs;
    use openzeppelin_access::ownable::OwnableComponent::InternalTrait as OwnableInternalTrait;
    use openzeppelin_access::ownable::OwnableComponent::OwnableImpl;
    use openzeppelin_token::erc20::interface::{IERC20CamelDispatcher, IERC20CamelDispatcherTrait};
    //use starknet::eth_signature::{verify_eth_signature};
    //use starknet::secp256_trait::signature_from_vrs;
    use starknet::storage::Map;
    use starknet::{EthAddress, get_caller_address, get_contract_address};
    use super::{ContractAddress};

    /// @notice Event emitted when a new session is created/joined
    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        SessionCreated: SessionCreated,
        SessionJoined: SessionJoined,
        ForcedSessionFinished: ForcedSessionFinished,
    }

    /// @notice Storage structure for the MarquisGame component
    #[storage]
    struct Storage {
        name: ByteArray,
        session_players: Map<(u256, u32), ContractAddress>,
        player_session: Map<ContractAddress, u256>,
        sessions: Map<u256, Session>,
        session_counter: u256,
        max_random_number: u256,
        initialized: bool,
        marquis_oracle_address: EthAddress,
        marquis_core_address: ContractAddress,
    }

    #[embeddable_as(MarquisGameImpl)]
    impl MarquisGame<
        TContractState,
        +HasComponent<TContractState>,
        impl Ownable: OwnableComponent::HasComponent<TContractState>,
        +Drop<TContractState>,
    > of IMarquisGame<ComponentState<TContractState>> {
        /// @notice Creates a new game session
        /// @param option_token The address of the token to be used in the session
        /// @param option_amount The amount of tokens to be used in the session
        /// @param option_players The array of players to be passed in a free session
        /// @param required_players The required players in the session
        /// @return session_id The ID of the newly created session
        fn create_session(
            ref self: ComponentState<TContractState>,
            option_token: Option<ContractAddress>,
            option_amount: Option<u256>,
            option_players: Option<Array<ContractAddress>>,
            required_players: u32,
        ) -> u256 {
            assert(
                required_players == 2 || required_players == 4, GameErrors::INVALID_PLAYERS_COUNT,
            );
            let mut session_id = self.session_counter.read() + 1;
            // initialize creator
            let creator = get_caller_address();
            self._require_player_has_no_session(creator);
            self._lock_user_to_session(session_id, creator);
            self.session_counter.write(session_id);

            let mut player_count = 1;
            let mut player_id = 0;

            // To play either a free or a paid session, 3 parameters play a role
            // If there is no amount, no token, but some players passed into this function,
            // initialize a free game.
            if option_amount.is_none() && option_token.is_none() && option_players.is_some() {
                let players: Array<ContractAddress> = option_players.unwrap();
                // the amount of players passed into option_players must be the total number of
                // players required minus the caller. Assert that the value matches for both
                // (required_players - 1) -- (2 - 1) and (4 - 1). Join players to the current
                // session.
                assert(players.len() == 1 || players.len() == 3, GameErrors::WRONG_INIT_PARAMS);
                player_count += players.len();
                self.session_players.write((session_id, player_id), creator);
                for player in players {
                    player_id += 1;
                    self._require_player_has_no_session(player);
                    self._lock_user_to_session(session_id, player);
                    self.session_players.write((session_id, player_id), player);
                };
            } else {
                // assert that the 3 parameters are exactly the opposite of the former check
                // if true, initialize a paid game, else panic.
                assert(
                    option_token.is_some() && option_amount.is_some() && option_players.is_none(),
                    GameErrors::WRONG_INIT_PARAMS,
                );
                self._require_stake_if_token_and_amount_are_some(option_token, option_amount);
                self.session_players.write((session_id, player_id), creator);
            }

            let mut new_session = Session {
                id: session_id,
                player_count,
                next_player_id: 0, // Todo: Refactor this, should be 0 or None?
                nonce: 0,
                option_amount,
                option_token,
                required_players,
            };
            self.sessions.write(session_id, new_session);

            self
                .emit(
                    SessionCreated {
                        session_id,
                        option_token,
                        option_amount,
                        creator,
                        required_players,
                        player_count,
                    },
                );
            session_id
        }

        // / @notice Allows a player to join an existing game session
        // / @param session_id The ID of the session to join
        fn join_session(ref self: ComponentState<TContractState>, session_id: u256) {
            let mut session = self.sessions.read(session_id);
            self._require_session_waiting(session_id);
            let player = get_caller_address();
            self._require_player_has_no_session(player);
            self._lock_user_to_session(session_id, player);

            // transfer the right amount of tokens
            self
                ._require_stake_if_token_and_amount_are_some(
                    session.option_token, session.option_amount,
                );

            // update session
            self.session_players.write((session.id, session.player_count), player);
            let player_count = session.player_count + 1;
            session.player_count = player_count;
            self.sessions.write(session_id, session);
            self.emit(SessionJoined { session_id, player, player_count: player_count });
        }

        /// @notice Gets the name of the game
        /// @return The name of the game as a ByteArray
        fn name(self: @ComponentState<TContractState>) -> ByteArray {
            self.name.read()
        }

        // ---------------- GETTERS ----------------

        /// @notice Gets the address of the Marquis Oracle
        /// @return EthAddress The address of the Marquis Oracle
        fn marquis_oracle_address(self: @ComponentState<TContractState>) -> EthAddress {
            self.marquis_oracle_address.read()
        }

        fn marquis_core_address(self: @ComponentState<TContractState>) -> ContractAddress {
            self.marquis_core_address.read()
        }

        fn is_supported_token(
            self: @ComponentState<TContractState>, token_address: ContractAddress,
        ) -> bool {
            let result = self._is_token_supported(token_address);
            result.is_some()
        }

        fn token_fee(self: @ComponentState<TContractState>, token_address: ContractAddress) -> u16 {
            let result = self._is_token_supported(token_address);
            *result.unwrap().fee
        }

        fn owner_finish_session(
            ref self: ComponentState<TContractState>,
            session_id: u256,
            option_winner_id: Option<u32>,
        ) {
            let mut ownable_component = get_dep_component_mut!(ref self, Ownable);
            ownable_component.assert_only_owner();
            let option_loser_id = Option::None;
            if let Option::None = self
                ._finish_session(session_id, option_winner_id, option_loser_id) {
                self.emit(ForcedSessionFinished { session_id });
            };
        }

        fn player_finish_session(
            ref self: ComponentState<TContractState>,
            session_id: u256,
            option_loser_id: Option<u32>,
        ) {
            let option_winner_id = Option::None;
            if let Option::None = self
                ._finish_session(session_id, option_winner_id, option_loser_id) {
                self.emit(ForcedSessionFinished { session_id });
            };
        }

        fn player_session(self: @ComponentState<TContractState>, player: ContractAddress) -> u256 {
            self.player_session.read(player)
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        impl Ownable: OwnableComponent::HasComponent<TContractState>,
        +Drop<TContractState>,
    > of InternalTrait<TContractState> {
        /// @notice Gets data of a specific game session
        /// @param session_id The ID of the session
        /// @return SessionData The data of the sessionchrome
        ///
        fn _get_session(self: @ComponentState<TContractState>, session_id: u256) -> SessionData {
            let session: Session = self.sessions.read(session_id);
            let session_next_player_id = self._session_next_player_id(session_id);
            SessionData {
                player_count: session.player_count,
                status: self._session_status(session_id),
                next_player: self.session_players.read((session_id, session_next_player_id)),
                nonce: session.nonce,
                option_amount: session.option_amount,
                option_token: session.option_token,
            }
        }

        /// @notice Checks if a player is not part of any session
        /// @param player The address of the player
        fn _require_player_has_no_session(
            ref self: ComponentState<TContractState>, player: ContractAddress,
        ) {
            let session_id = self.player_session.read(player);
            assert(session_id == 0, GameErrors::PLAYER_HAS_SESSION);
        }

        /// @notice Ensures the next player in the session is the caller
        /// @param session_id The ID of the session
        /// @param player The address of the player
        fn _require_next_player_in_session(
            ref self: ComponentState<TContractState>,
            session_id: u256,
            player: ContractAddress,
            is_owner: bool,
        ) {
            let session_next_player_id = self._session_next_player_id(session_id);
            let mut ownable_component = get_dep_component_mut!(ref self, Ownable);

            let session_player = match is_owner {
                true => ownable_component.owner(),
                false => self.session_players.read((session_id, session_next_player_id)),
            };

            assert(session_player == player, GameErrors::NOT_PLAYER_TURN);
        }

        /// @notice Ensures the session is in the waiting state
        /// @param session_id The ID of the session
        fn _require_session_waiting(ref self: ComponentState<TContractState>, session_id: u256) {
            assert(
                self._session_status(session_id) == GameStatus::WAITING,
                SessionErrors::SESSION_NOT_WAITING,
            );
        }

        /// @notice Ensures the session is in the playing state
        /// @param session_id The ID of the session
        fn _require_session_playing(ref self: ComponentState<TContractState>, session_id: u256) {
            assert(
                self._session_status(session_id) == GameStatus::PLAYING,
                SessionErrors::SESSION_NOT_PLAYING,
            );
        }

        /// @notice Ensures the session exists
        /// @param session_id The ID of the session
        fn _require_session_exists(ref self: ComponentState<TContractState>, session_id: u256) {
            let session: Session = self.sessions.read(session_id);
            assert(session.id != 0, SessionErrors::SESSION_NOT_FOUND);
        }

        /// @notice Locks a user to a session
        /// @param session_id The ID of the session
        /// @param player The address of the player
        fn _lock_user_to_session(
            ref self: ComponentState<TContractState>, session_id: u256, player: ContractAddress,
        ) {
            self.player_session.write(player, session_id);
        }

        /// @notice Unlocks a user from a session
        /// @param session_id The ID of the session
        /// @param player The address of the player
        fn _unlock_user_from_session(
            ref self: ComponentState<TContractState>, session_id: u256, player: ContractAddress,
        ) {
            self.player_session.write(player, 0);
        }

        /// @notice Ensures the contract is initialized
        fn _require_initialized(ref self: ComponentState<TContractState>) {
            assert(self.initialized.read(), GameErrors::NOT_INITIALIZED);
        }

        /// @notice Performs necessary checks and updates before a play action
        /// @param session_id The ID of the session
        /// @param verifiableRandomNumberArray Array of verifiable random numbers
        /// @return (Session, Array<u256>) The session and array of random numbers
        fn _before_play(
            ref self: ComponentState<TContractState>,
            session_id: u256,
            mut verifiableRandomNumberArray: Array<VerifiableRandomNumber>,
            is_owner: bool,
        ) -> (Session, Array<u256>) {
            // read the session
            let mut session: Session = self.sessions.read(session_id);
            let mut ownable_component = get_dep_component_mut!(ref self, Ownable);

            let player = match is_owner {
                true => ownable_component.owner(),
                false => get_caller_address(),
            };

            // pre checks
            self._require_initialized();
            self._require_session_playing(session.id);
            self._require_next_player_in_session(session.id, player, is_owner);
            // update session play_count
            session.nonce += 1;
            // let player_as_felt252: felt252 = get_caller_address().into();
            // let player_as_u256: u256 = player_as_felt252.into();
            // let this_contract_as_felt252: felt252 = get_contract_address().into();
            // let this_contract_as_u256: u256 = this_contract_as_felt252.into();
            let mut random_number_array: Array<u256> = array![];
            loop {
                if (verifiableRandomNumberArray.len() == 0) {
                    break;
                }
                let verifiableRandomNumber = verifiableRandomNumberArray.pop_front().unwrap();
                assert(
                    verifiableRandomNumber.random_number <= self.max_random_number.read(),
                    GameErrors::INVALID_RANDOM_NUMBER,
                );
                let random_number = verifiableRandomNumber.random_number;
                // let _v = verifiableRandomNumber.v;
                // let _r = verifiableRandomNumber.r;
                // let _s = verifiableRandomNumber.s;

                // let u256_inputs = array![
                //     session.id, session.nonce,random_number, player_as_u256,
                //     this_contract_as_u256
                // ];
                // let message_hash = keccak_u256s_le_inputs(u256_inputs.span());
                // let signature = format!("{}-{}-{}-{}-{}", random_number, _v, _r, _s,
                // message_hash);
                // println!("signature: {}", signature);
                // verify_eth_signature(
                //     message_hash, signature_from_vrs(_v, _r, _s),
                //     self.marquis_oracle_address.read()
                // );
                random_number_array.append(random_number);
            };

            self
                .sessions
                .write(
                    session.id,
                    Session {
                        id: session.id,
                        player_count: session.player_count,
                        next_player_id: session.next_player_id,
                        nonce: session.nonce,
                        option_amount: session.option_amount,
                        option_token: session.option_token,
                        required_players: session.required_players,
                    },
                );

            (session, random_number_array)
        }

        /// @notice Updates session details after a play action
        /// @param session_id The ID of the session
        fn _after_play(ref self: ComponentState<TContractState>, session_id: u256) {
            let mut session: Session = self.sessions.read(session_id);
            let mut next_player_id = self._session_next_player_id(session_id);
            if next_player_id + 1 == session.player_count {
                session.next_player_id = 0;
            } else {
                session.next_player_id = next_player_id + 1;
            }
            self.sessions.write(session.id, session);
        }

        /// @notice Finishes a session and unlocks all players
        /// @param session_id The ID of the session
        /// @param winner_id The ID of the winning player
        fn _finish_session(
            ref self: ComponentState<TContractState>,
            session_id: u256,
            option_winner_id: Option<u32>,
            option_loser_id: Option<u32>,
        ) -> Option<u256> {
            let mut session: Session = self.sessions.read(session_id);
            // unlock all players
            let mut it: u32 = 0;
            let total_players = session.player_count;
            let play_token = session.option_token;
            let result = match play_token {
                Option::Some(token) => { self.is_supported_token(token) },
                Option::None => false // Free session
            };

            let fee_basis = Constants::FEE_MAX;
            loop {
                let player = self.session_players.read((session.id, it));
                if player == Zero::zero() {
                    break;
                }

                self._unlock_user_from_session(session.id, player);
                it += 1;
            };
            let mut result_amount: Option<u256> = Option::None;
            if result {
                /// It means we created a session with a token option, so we need to calculate the
                /// rewards, payments, etc.
                /// Safe to unwrap here because we checked that result is some
                let play_amount = session.option_amount.unwrap();
                let play_token = session.option_token.unwrap();
                let fee = self.token_fee(play_token);
                result_amount = match option_winner_id {
                    Option::None => {
                        match option_loser_id {
                            Option::Some(loser_id) => {
                                // all players except the loser
                                let amount_per_player = play_amount
                                    * total_players.into()
                                    / (total_players - 1).into();
                                let arr = if total_players == 2 {
                                    [0, 1].span()
                                } else if total_players == 4 {
                                    [0, 1, 2, 3].span()
                                } else {
                                    panic_with_felt252(GameErrors::INVALID_PLAYERS_COUNT)
                                };

                                for player_id in arr {
                                    if (*player_id).into() == loser_id {
                                        continue;
                                    }
                                    let player = self
                                        .session_players
                                        .read((session.id, *player_id));
                                    self
                                        ._execute_payout(
                                            play_token,
                                            amount_per_player,
                                            player,
                                            Option::None,
                                            fee_basis,
                                        );
                                };
                                Option::None
                            },
                            Option::None => {
                                for mut i in 0..total_players {
                                    let player = self.session_players.read((session.id, i));
                                    self
                                        ._execute_payout(
                                            play_token,
                                            play_amount,
                                            player,
                                            Option::None,
                                            fee_basis,
                                        );
                                };
                                Option::None
                            },
                        }
                    },
                    Option::Some(winner_id) => {
                        let total_play_amount = play_amount * total_players.into();
                        let player = self.session_players.read((session.id, winner_id));
                        let winner_amount = self
                            ._execute_payout(
                                play_token,
                                total_play_amount,
                                player,
                                Option::Some(@fee),
                                fee_basis,
                            );
                        Option::Some(winner_amount)
                    },
                };
            };
            session.player_count = 0;
            self.sessions.write(session.id, session);
            result_amount
        }

        /// @notice Gets the status of a session
        /// @param session_id The ID of the session
        /// @return felt252 The status of the session
        fn _session_status(self: @ComponentState<TContractState>, session_id: u256) -> felt252 {
            let session: Session = self.sessions.read(session_id);
            if session.player_count == session.required_players {
                return GameStatus::PLAYING;
                // Todo: Refactor this logic to check if the session is playing
            } else if session.player_count == 0 {
                return GameStatus::FINISHED;
            }
            return GameStatus::WAITING;
        }

        /// @notice Gets the next player ID and time left to play in a session
        /// @param session_id The ID of the session
        /// @return (u32, u64) The next player ID and time left to play
        fn _session_next_player_id(self: @ComponentState<TContractState>, session_id: u256) -> u32 {
            let session: Session = self.sessions.read(session_id);
            session.next_player_id
        }

        /// @notice Checks if the token is supported
        /// @param token_address The address of the token to check
        /// @return u16 The fee associated with the token
        fn _require_supported_token(
            ref self: ComponentState<TContractState>, token_address: ContractAddress,
        ) {
            let result = self._is_token_supported(token_address);
            assert(result.is_some(), GameErrors::UNSUPPORTED_TOKEN);
        }

        fn _is_token_supported(
            self: @ComponentState<TContractState>, token_address: ContractAddress,
        ) -> Option<@SupportedToken> {
            let marquis_core_dispatcher = IMarquisCoreDispatcher {
                contract_address: self.marquis_core_address.read(),
            };
            let mut supported_tokens = marquis_core_dispatcher.get_all_supported_tokens();
            let mut supported_token = Option::None;
            let len = supported_tokens.len();
            for mut i in 0..len {
                let token = supported_tokens.pop_front().unwrap();
                if *token.token_address == token_address {
                    supported_token = Option::Some(token);
                    break;
                }
                i = i + 1;
            };
            supported_token
        }


        /// @notice Requires payment if the token is some and amount is some
        /// @param token The address of the token
        /// @param amount The amount to be transferred
        fn _require_stake_if_token_and_amount_are_some(
            ref self: ComponentState<TContractState>,
            option_token: Option<ContractAddress>,
            option_amount: Option<u256>,
        ) {
            match (option_token, option_amount) {
                (Option::Some(token), Option::Some(amount)) => if token != Zero::zero() {
                    self._require_supported_token(token);
                    IERC20CamelDispatcher { contract_address: token }
                        .transferFrom(get_caller_address(), get_contract_address(), amount);
                },
                (Option::None, Option::None) => (),
                _ => panic_with_felt252(GameErrors::INVALID_GAME_MODE),
            };
        }

        /// @notice Executes payout if the token is
        /// @param token The address of the token
        /// @param amount The amount to be paid out
        /// @param payout_addr The address to receive the payout
        // Todo: Refactor this logic to calculate the total play amount for all players except the
        // loser
        fn _execute_payout(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            mut amount: u256,
            payout_addr: ContractAddress,
            fee: Option<@u16>,
            fee_basis: u16,
        ) -> u256 {
            if let Option::Some(fee) = fee {
                let fee: u16 = *fee;
                let total_fee: u256 = fee.into() * amount / fee_basis.into();
                IERC20CamelDispatcher { contract_address: token }
                    .transfer(self.marquis_core_address.read(), total_fee);
                amount -= total_fee;
            };
            IERC20CamelDispatcher { contract_address: token }.transfer(payout_addr, amount);
            amount
        }

        /// @notice Initializes the MarquisGame component with the provided parameters
        /// @param name The name of the game
        /// @param max_players The maximum number of players
        /// @param min_players The minimum number of players
        /// @param join_waiting_time The waiting time to join the game
        /// @param play_waiting_time The waiting time to play the game
        /// @param marquis_core_addr The address of the Marquis core
        fn initializer(ref self: ComponentState<TContractState>, init_params: InitParams) {
            let InitParams {
                name, marquis_oracle_address, max_random_number, marquis_core_address, owner,
            } = init_params;

            assert(!self.initialized.read(), GameErrors::ALREADY_INITIALIZED);
            self.name.write(name);
            self.max_random_number.write(max_random_number);
            self.marquis_oracle_address.write(marquis_oracle_address);
            self.marquis_core_address.write(marquis_core_address);

            let mut ownable_component = get_dep_component_mut!(ref self, Ownable);
            ownable_component.initializer(owner);
            self.initialized.write(true);
        }
    }
}
