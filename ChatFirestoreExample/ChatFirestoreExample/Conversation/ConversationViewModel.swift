//
//  ConversationViewModel.swift
//  ChatFirestoreExample
//
//  Created by Alisa Mylnikova on 13.06.2023.
//

import Foundation
import FirebaseFirestore
import FirebaseFirestoreSwift
import Chat

@MainActor
class ConversationViewModel: ObservableObject {

    var users: [User] // not including current user
    var allUsers: [User]

    var conversation: Conversation?
    var messagesCollection: CollectionReference?

    @Published var messages: [Message] = []

    private var subscribtionToConversationCreation: ListenerRegistration?

    init(user: User) {
        self.users = [user]
        self.allUsers = [user]
        if let currentUser = SessionManager.shared.currentUser {
            self.allUsers.append(currentUser)
        }
        // setup conversation and messagesCollection later, after it's created
        // either when another user creates it by sending the first message
        subscribeToConversationCreation(user: user)
        // or when this user sends first message
    }

    init(conversation: Conversation) {
        self.users = conversation.users.filter { $0.id != SessionManager.shared.currentUserId }
        self.allUsers = conversation.users
        updateForConversation(conversation)
    }

    func updateForConversation(_ conversation: Conversation) {
        self.conversation = conversation
        self.messagesCollection = makeMessagesCollectionRef(conversation)
        subscribeToMessages()
    }

    func makeMessagesCollectionRef(_ conversation: Conversation) -> CollectionReference {
        Firestore.firestore()
            .collection(Collection.conversations)
            .document(conversation.id)
            .collection(Collection.messages)
    }

    // MARK: - get/send messages

    func subscribeToMessages() {
        messagesCollection?
            .order(by: "createdAt", descending: false)
            .addSnapshotListener() { [weak self] (snapshot, _) in
                let messages = snapshot?.documents
                    .compactMap { try? $0.data(as: FirestoreMessage.self) }
                    .compactMap { firestoreMessage -> Message? in
                        guard
                            let id = firestoreMessage.id,
                            let user = self?.allUsers.first(where: { $0.id == firestoreMessage.userId }),
                            let date = firestoreMessage.createdAt
                        else { return nil }

                        let convertAttachments: ([FirestoreAttachment]) -> [Attachment] = { attachments in
                            attachments.compactMap {
                                if let url = $0.url.toURL() {
                                    return Attachment(id: UUID().uuidString, url: url, type: $0.type)
                                }
                                return nil
                            }
                        }

                        var replyMessage: ReplyMessage?
                        if let reply = firestoreMessage.replyMessage,
                           let replyId = reply.id,
                           let replyUser = self?.allUsers.first(where: { $0.id == reply.userId }) {
                            replyMessage = ReplyMessage(
                                id: replyId,
                                user: replyUser,
                                text: reply.text,
                                attachments: convertAttachments(reply.attachments),
                                recording: nil)
                        }

                        return Message(
                            id: id,
                            user: user,
                            status: .sent,
                            createdAt: date,
                            text: firestoreMessage.text,
                            attachments: convertAttachments(firestoreMessage.attachments),
                            recording: firestoreMessage.recording,
                            replyMessage: replyMessage)
                    }
                self?.messages = messages ?? []
            }
    }

    func sendMessage(_ draft: DraftMessage) {
        Task {
            /// create conversation in Firestore if needed
            // only create individual conversation when first message is sent
            // group conversation was created before (UsersViewModel)
            if conversation == nil,
               users.count == 1,
               let user = users.first,
               let conversation = await createIndividualConversation(user) {
                updateForConversation(conversation)
            }

            /// precreate message with fixed id and .sending status
            guard let user = SessionManager.shared.currentUser else { return }
            let id = UUID().uuidString
            let message = await Message.makeMessage(id: id, user: user, status: .sending, draft: draft)
            messages.append(message)

            /// convert to Firestore dictionary: replace users with userIds, upload medias and get urls, replace urls with strings
            let dict = await makeDraftMessageDictionary(draft)

            /// upload dictionary with the same id we fixed earlier, so Caht knows it's still the same message
            do {
                try await messagesCollection?.document(id).setData(dict)
                if let index = messages.lastIndex(where: { $0.id == id }) {
                    messages[index].status = .sent
                }
            } catch {
                print("Error adding document: \(error)")
                if let index = messages.lastIndex(where: { $0.id == id }) {
                    messages[index].status = .error(draft)
                }
            }

            /// update latest message in current conversation to be this one
            if let id = conversation?.id {
                try await Firestore.firestore()
                    .collection(Collection.conversations)
                    .document(id)
                    .updateData(["latestMessage" : dict])
            }
        }
    }

    private func makeDraftMessageDictionary(_ draft: DraftMessage) async -> [String: Any] {
        guard let user = SessionManager.shared.currentUser else { return [:] }
        var attachments = [[String: Any]]()
        for media in draft.medias {
            let url = await UploadingManager.uploadMedia(media)
            if let url = url {
                attachments.append([
                    "url": url.absoluteString,
                    "type": AttachmentType(mediaType: media.type).rawValue
                ])
            }
        }

        var replyDict: [String: Any]? = nil
        if let reply = draft.replyMessage {
            replyDict = [
                "id": reply.id,
                "userId": reply.user.id,
                "text": reply.text,
                "attachments": reply.attachments.map { [
                    "url": $0.full.absoluteString,
                    "type": $0.type.rawValue
                ] },
            ]
        }

        return [
            "userId": user.id,
            "createdAt": Timestamp(date: draft.createdAt),
            "text": draft.text,
            "attachments": attachments,
            "replyMessage": replyDict as Any
        ]
    }

    // MARK: - conversation life management

    func subscribeToConversationCreation(user: User) {
        subscribtionToConversationCreation = Firestore.firestore()
            .collection(Collection.conversations)
            .whereField("users", arrayContains: SessionManager.shared.currentUserId)
            .addSnapshotListener() { [weak self] (snapshot, _) in
                // check if this convesation was created by another user already
                if let conversation = self?.conversationForUser(user) {
                    self?.updateForConversation(conversation)
                    self?.subscribtionToConversationCreation = nil
                }
            }
    }

    private func conversationForUser(_ user: User) -> Conversation? {
        // check in case the other user sent a message while this user had the empty conversation open
        for conversation in dataStorage.conversations {
            if conversation.users.count == 2, conversation.users.contains(user) {
                return conversation
            }
        }
        return nil
    }

    private func createIndividualConversation(_ user: User) async -> Conversation? {
        subscribtionToConversationCreation = nil
        let dict: [String : Any] = [
            "users": allUsers.map { $0.id },
            "title": user.name
        ]

        return await withCheckedContinuation { continuation in
            var ref: DocumentReference? = nil
            ref = Firestore.firestore()
                .collection(Collection.conversations)
                .addDocument(data: dict) { err in
                    if let _ = err {
                        continuation.resume(returning: nil)
                    } else if let id = ref?.documentID {
                        continuation.resume(returning: Conversation(id: id, users: self.allUsers, pictureURL: nil, title: "", latestMessage: nil))
                    }
                }
        }
    }
}
