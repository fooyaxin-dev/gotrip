const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const { documentId } = require("@firebase/firestore");
const fs = require("fs");
const path = require("path");

const PROJECT_ID = "gotrip-rules-test";
let testEnv;

describe("GoTrip Task 8C — Firestore Security Rules Unit Tests", () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: {
        rules: fs.readFileSync(path.join(__dirname, "firestore.rules"), "utf8"),
      },
    });
  });

  beforeEach(async () => {
    await testEnv.clearFirestore();
  });

  after(async () => {
    await testEnv.cleanup();
  });

  // 1. Unauthenticated user cannot read users
  it("1. Unauthenticated user cannot read users", async () => {
    const unauthedDb = testEnv.unauthenticatedContext().firestore();
    await assertFails(unauthedDb.collection("users").doc("user1").get());
  });

  // 2. Authenticated user can read a user document required for author display
  it("2. Authenticated user can read a user document required for author display", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("users").doc("user2_author").set({
        username: "Alice",
        profileImageUrl: "https://example.com/avatar.jpg",
      });
    });
    const user2Db = testEnv.authenticatedContext("user2_viewer").firestore();
    await assertSucceeds(user2Db.collection("users").doc("user2_author").get());
  });

  // 3. User A cannot update User B's profile
  it("3. User A cannot update User B's profile", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("users").doc("user3_B").set({
        username: "Bob",
      });
    });
    const user3ADb = testEnv.authenticatedContext("user3_A").firestore();
    await assertFails(
      user3ADb.collection("users").doc("user3_B").update({ username: "Hacked" })
    );
  });

  // 4. User A can update their own permitted profile fields
  it("4. User A can update their own permitted profile fields", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("users").doc("user4").set({
        username: "Alice",
        bio: "Original bio",
      });
    });
    const user4Db = testEnv.authenticatedContext("user4").firestore();
    await assertSucceeds(
      user4Db.collection("users").doc("user4").update({ bio: "Updated bio" })
    );
  });

  // 5. Unauthenticated user cannot read post
  it("5. Unauthenticated user cannot read public post (app requires sign in)", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post5").set({
        userId: "author5",
        visibility: "public",
        title: "Public Post",
      });
    });
    const unauthedDb = testEnv.unauthenticatedContext().firestore();
    await assertFails(unauthedDb.collection("posts").doc("post5").get());
  });

  // 6. Authenticated user can read a public post
  it("6. Authenticated user can read a public post", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post6").set({
        userId: "author6",
        visibility: "public",
        title: "Public Post",
      });
    });
    const user6Db = testEnv.authenticatedContext("user6").firestore();
    await assertSucceeds(user6Db.collection("posts").doc("post6").get());
  });

  // 7. User A cannot read User B's private post
  it("7. User A cannot read User B's private post", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post7_private").set({
        userId: "user7_B",
        visibility: "private",
        title: "Bob's Secret",
      });
    });
    const user7ADb = testEnv.authenticatedContext("user7_A").firestore();
    await assertFails(user7ADb.collection("posts").doc("post7_private").get());
  });

  // 8. User A cannot read User B's friends-only post without enforceable friendship
  it("8. User A cannot read User B's friends-only post", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post8_friends").set({
        userId: "user8_B",
        visibility: "friends",
        title: "Bob's Friends Post",
      });
    });
    const user8ADb = testEnv.authenticatedContext("user8_A").firestore();
    await assertFails(user8ADb.collection("posts").doc("post8_friends").get());
  });

  // 9. Owner can read their own private post
  it("9. Owner can read their own private post", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post9_private").set({
        userId: "user9",
        visibility: "private",
        title: "My Secret",
      });
    });
    const user9Db = testEnv.authenticatedContext("user9").firestore();
    await assertSucceeds(user9Db.collection("posts").doc("post9_private").get());
  });

  // 10. Public-post feed query succeeds when it includes visibility == 'public'
  it("10. Public-post feed query succeeds when it includes visibility == 'public'", async () => {
    const user10Db = testEnv.authenticatedContext("user10").firestore();
    await assertSucceeds(
      user10Db.collection("posts").where("visibility", "==", "public").get()
    );
  });

  // 11. An unconstrained all-post query is denied
  it("11. An unconstrained all-post query is denied", async () => {
    const user11Db = testEnv.authenticatedContext("user11").firestore();
    await assertFails(user11Db.collection("posts").get());
  });

  // 12. Public Algolia hydration-style query succeeds
  it("12. Public Algolia hydration-style query succeeds", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await adminDb.collection("posts").doc("post12_1").set({
        userId: "author12",
        title: "Post 1",
        visibility: "public",
      });
      await adminDb.collection("posts").doc("post12_2").set({
        userId: "author12",
        title: "Post 2",
        visibility: "public",
      });
    });
    const user12Db = testEnv.authenticatedContext("user12").firestore();
    await assertSucceeds(
      user12Db
        .collection("posts")
        .where("visibility", "==", "public")
        .where(documentId(), "in", ["post12_1", "post12_2"])
        .get()
    );
  });

  // 13. User cannot create a post using another user's UID
  it("13. User cannot create a post using another user's UID", async () => {
    const user13Db = testEnv.authenticatedContext("user13_A").firestore();
    await assertFails(
      user13Db.collection("posts").doc("fakePost13").set({
        userId: "user13_B",
        title: "Impersonated",
        content: "Content",
        visibility: "public",
        likes: 0,
        comments: 0,
        shares: 0,
      })
    );
  });

  // 14. Post owner can perform the exact production edit
  it("14. Post owner can perform the exact production edit", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post14").set({
        userId: "user14",
        title: "Old Title",
        content: "Old Content",
        visibility: "public",
        tags: ["travel"],
        createdAt: "2026-09-01T00:00:00Z",
        likes: 0,
        comments: 0,
        shares: 0,
      });
    });
    const user14Db = testEnv.authenticatedContext("user14").firestore();
    await assertSucceeds(
      user14Db.collection("posts").doc("post14").update({
        title: "New Title",
        content: "New Content",
        visibility: "public",
        tags: ["travel", "vacation"],
      })
    );
  });

  // 15. Post owner cannot change protected ownership fields
  it("15. Post owner cannot change protected ownership fields", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post15").set({
        userId: "user15_A",
        title: "Title",
        content: "Content",
        visibility: "public",
        tags: [],
        createdAt: "2026-09-01T00:00:00Z",
        likes: 0,
        comments: 0,
        shares: 0,
      });
    });
    const user15Db = testEnv.authenticatedContext("user15_A").firestore();
    await assertFails(
      user15Db.collection("posts").doc("post15").update({
        userId: "user15_B",
      })
    );
  });

  // 16. User cannot set likes from 0 to 500
  it("16. User cannot set likes from 0 to 500", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post16").set({
        userId: "author16",
        title: "Title",
        content: "Content",
        visibility: "public",
        createdAt: "2026-09-01T00:00:00Z",
        likes: 0,
        comments: 0,
        shares: 0,
      });
    });
    const user16Db = testEnv.authenticatedContext("user16").firestore();
    await assertFails(
      user16Db.collection("posts").doc("post16").update({ likes: 500 })
    );
  });

  // 17. User cannot increment likes without creating like doc
  it("17. User cannot increment likes without creating like doc in atomic transaction", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post17").set({
        userId: "author17",
        title: "Title",
        content: "Content",
        visibility: "public",
        createdAt: "2026-09-01T00:00:00Z",
        likes: 0,
        comments: 0,
        shares: 0,
      });
    });
    const user17Db = testEnv.authenticatedContext("user17").firestore();
    await assertFails(
      user17Db.collection("posts").doc("post17").update({ likes: 1 })
    );
  });

  // 18. User cannot create a like document without valid post counter transition
  it("18. User cannot create a like document without matching post counter transition", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post18").set({
        userId: "author18",
        title: "Title",
        content: "Content",
        visibility: "public",
        createdAt: "2026-09-01T00:00:00Z",
        likes: 0,
        comments: 0,
        shares: 0,
      });
    });
    const user18Db = testEnv.authenticatedContext("user18").firestore();
    await assertFails(
      user18Db
        .collection("posts")
        .doc("post18")
        .collection("likes")
        .doc("user18")
        .set({ userId: "user18" })
    );
  });

  // 19. Valid like transaction succeeds
  it("19. Valid like transaction succeeds", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection("posts").doc("post19").set({
        userId: "author19",
        title: "Title",
        content: "Content",
        visibility: "public",
        createdAt: "2026-09-01T00:00:00Z",
        likes: 0,
        comments: 0,
        shares: 0,
      });
    });
    const user19Db = testEnv.authenticatedContext("user19").firestore();
    await assertSucceeds(
      user19Db.runTransaction(async (transaction) => {
        const postRef = user19Db.collection("posts").doc("post19");
        const likeRef = postRef.collection("likes").doc("user19");
        const postDoc = await transaction.get(postRef);
        const currentLikes = postDoc.data().likes;
        transaction.set(likeRef, { userId: "user19" });
        transaction.update(postRef, { likes: currentLikes + 1 });
      })
    );
  });

  // 20. Duplicate like attempt fails
  it("20. Duplicate like attempt fails", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await adminDb.collection("posts").doc("post20").set({
        userId: "author20",
        title: "Title",
        content: "Content",
        visibility: "public",
        createdAt: "2026-09-01T00:00:00Z",
        likes: 1,
        comments: 0,
        shares: 0,
      });
      await adminDb
        .collection("posts")
        .doc("post20")
        .collection("likes")
        .doc("user20")
        .set({ userId: "user20" });
    });
    const user20Db = testEnv.authenticatedContext("user20").firestore();
    await assertFails(
      user20Db.runTransaction(async (transaction) => {
        const postRef = user20Db.collection("posts").doc("post20");
        const likeRef = postRef.collection("likes").doc("user20");
        const postDoc = await transaction.get(postRef);
        const currentLikes = postDoc.data().likes;
        transaction.set(likeRef, { userId: "user20" });
        transaction.update(postRef, { likes: currentLikes + 1 });
      })
    );
  });

  // 21. Valid unlike transaction succeeds
  it("21. Valid unlike transaction succeeds", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await adminDb.collection("posts").doc("post21").set({
        userId: "author21",
        title: "Title",
        content: "Content",
        visibility: "public",
        createdAt: "2026-09-01T00:00:00Z",
        likes: 1,
        comments: 0,
        shares: 0,
      });
      await adminDb
        .collection("posts")
        .doc("post21")
        .collection("likes")
        .doc("user21")
        .set({ userId: "user21" });
    });
    const user21Db = testEnv.authenticatedContext("user21").firestore();
    await assertSucceeds(
      user21Db.runTransaction(async (transaction) => {
        const postRef = user21Db.collection("posts").doc("post21");
        const likeRef = postRef.collection("likes").doc("user21");
        const postDoc = await transaction.get(postRef);
        const currentLikes = postDoc.data().likes;
        transaction.delete(likeRef);
        transaction.update(postRef, { likes: currentLikes - 1 });
      })
    );
  });

  // 22. Unlike below zero fails
  it("22. Unlike below zero fails", async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await adminDb.collection("posts").doc("post22").set({
        userId: "author22",
        title: "Title",
        content: "Content",
        visibility: "public",
        createdAt: "2026-09-01T00:00:00Z",
        likes: 0,
        comments: 0,
        shares: 0,
      });
      await adminDb
        .collection("posts")
        .doc("post22")
        .collection("likes")
        .doc("user22")
        .set({ userId: "user22" });
    });
    const user22Db = testEnv.authenticatedContext("user22").firestore();
    await assertFails(
      user22Db.runTransaction(async (transaction) => {
        const postRef = user22Db.collection("posts").doc("post22");
        const likeRef = postRef.collection("likes").doc("user22");
        transaction.delete(likeRef);
        transaction.update(postRef, { likes: -1 });
      })
    );
  });

  // 23. User cannot create/delete another user's like document
  it("23. User cannot create/delete another user's like document", async () => {
    const user23Db = testEnv.authenticatedContext("user23_A").firestore();
    await assertFails(
      user23Db
        .collection("posts")
        .doc("post23")
        .collection("likes")
        .doc("user23_B")
        .set({ userId: "user23_B" })
    );
  });

  // 24. Unauthorized user cannot access another user's private subcollections
  it("24. Unauthorized user cannot access another user's private subcollections", async () => {
    const user24Db = testEnv.authenticatedContext("user24_A").firestore();
    await assertFails(
      user24Db
        .collection("users")
        .doc("user24_B")
        .collection("itineraries")
        .doc("trip24")
        .get()
    );
  });

  // 25. Valid owner subcollection access succeeds
  it("25. Valid owner subcollection access succeeds", async () => {
    const user25Db = testEnv.authenticatedContext("user25").firestore();
    await assertSucceeds(
      user25Db
        .collection("users")
        .doc("user25")
        .collection("itineraries")
        .doc("trip25")
        .set({ title: "My Trip", destination: "Tokyo" })
    );
  });

  // 26. Unauthenticated cache write fails
  it("26. Unauthenticated cache write fails", async () => {
    const unauthedDb = testEnv.unauthenticatedContext().firestore();
    await assertFails(
      unauthedDb.collection("place_details").doc("place26").set({
        name: "Test Place",
      })
    );
  });

  // 27. Required authenticated cache write succeeds
  it("27. Required authenticated cache write succeeds", async () => {
    const user27Db = testEnv.authenticatedContext("user27").firestore();
    await assertSucceeds(
      user27Db.collection("place_details").doc("place27").set({
        name: "Test Place",
      })
    );
  });

  // 28. Unknown/unmatched collection access fails
  it("28. Unknown/unmatched collection access fails", async () => {
    const user28Db = testEnv.authenticatedContext("user28").firestore();
    await assertFails(
      user28Db.collection("secret_admin_data").doc("doc28").get()
    );
  });
});